# Use UPNP to open a port on the firewall.
#
# This is a pure-ruby implementation of the bare-minimum portions of UPNP
# necessary to open a port in the firewall.

require 'socket'
require 'net/http'
require 'uri'
require 'rexml/document'
require 'rexml/xpath'
require_relative 'simple_thread'

class UPnP
  DURATION = 600

  # Start background thread to interact with the UPNP server.  `port` is the
  # port that we'd like to have open.
  def self.start port
    SimpleThread.new 'upnp' do
      loop do
        begin
          open 'TCP', port, port
        rescue
          Log.warn "Problem in UPnP: #{$!}"
        end
        gsleep DURATION
      end
    end
  end

  private

  # Open a port.  Usually this is best done by `start`.
  def self.open protocol, external_port, internal_port
    urls = discover_root_device

    raise "No UPnP root devices found" if urls.empty?

    opened = false

    internal_ip = nil

    urls.each do |url|
      control_url = query_control_url url
      next unless control_url

      internal_ip ||= get_internal_address

      res = request_port({
        control: control_url,
        internal_ip: internal_ip,
        protocol: protocol,
        external_port: external_port,
        internal_port: internal_port,
      })

      opened ||= res
      timeout = Time.new + DURATION

      if res
        at_exit { delete_port({
          control: control_url,
          protocol: protocol,
          external_port: external_port,
          timeout: timeout
        }) }
        break
      end
    end

    opened
  end

  # Find the root device on the network via UDP broadcast.
  def self.discover_root_device
    udp = UDPSocket.new
    search_str = <<EOF
M-SEARCH * HTTP/1.1
Host: 239.255.255.250:1900
Man: "ssdp:discover"
ST: upnp:rootdevice
MX: 3

EOF
    search_str.gsub! "\n", "\r\n"
    gunlock {
      udp.send search_str, 0, "239.255.255.250", 1900
    }
    responses = []

    # Wait for multiple responses
    gsleep 0.5

    begin
      loop do
        responses.push udp.recv_nonblock(4096)
      end
    rescue Errno::EAGAIN
    end

    urls = []

    responses.each do |response|
      next unless response =~ /^Location: (http:\/\/.*?)\r\n/i
      urls << $1
    end

    urls
  end

  # Ask the root device it's control URL
  def self.query_control_url device_url
    uri = URI.parse device_url
    res = gunlock { Net::HTTP.get_response(uri) }

    if !res.is_a? Net::HTTPSuccess
      Log.warn "UPnP warning: Could not fetch description XML at #{url}"
      return
    end

    doc = REXML::Document.new res.body
    doc.elements.each( "//service" ) do |service|
      wan_config = "urn:schemas-upnp-org:service:WANIPConnection:1"

      next unless service.elements["serviceType"].text == wan_config
      control = service.elements["controlURL"].text
      if control !~ /^http:\/\//
        control = "http://#{uri.host}:#{uri.port}#{control}"
      end

      return control
    end

    nil
  end

  # Get our internal address
  def self.get_internal_address
    udp = UDPSocket.new

    # we don't actually connect, but by pretending to do so we see what our
    # source address is
    udp.connect '8.8.8.8', 53

    internal_ip = udp.addr[3]
    raise "Cannot discover local IP address" unless internal_ip

    internal_ip
  end


  # Net::HTTP doesn't preserve the case of HTTP headers (it shouldn't need to
  # since they are supposed to be case insensitive), but tell that to router
  # manufacturers.  Make a special String class that can't be downcased.
  class KeepCase < String
    def downcase
      self
    end
  end

  # Ask router for port
  def self.request_port opts
    namespace = "service:WANIPConnection:1"
    return false unless send_soap opts[:control], namespace, :AddPortMapping, <<EOF
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>#{opts[:external_port]}</NewExternalPort>
<NewProtocol>#{opts[:protocol]}</NewProtocol>
<NewInternalPort>#{opts[:internal_port]}</NewInternalPort>
<NewInternalClient>#{opts[:internal_ip]}</NewInternalClient>
<NewEnabled>1</NewEnabled>
<NewPortMappingDescription>clearskies (#{opts[:internal_ip]}:#{opts[:internal_port]}) #{opts[:external_port]} #{opts[:protocol]}</NewPortMappingDescription>
<NewLeaseDuration>#{DURATION}</NewLeaseDuration>
EOF

    Log.info "UPnP router #{URI.parse(opts[:control]).host} is forwarding #{opts[:external_port]} to #{opts[:internal_ip]}:#{opts[:internal_port]}, expires in #{DURATION} s."
    return true
  end

  # Remove router port mapping
  def self.delete_port opts
    return if Time.new > opts[:timeout]
    namespace = "service:WANIPConnection:1"
    return false unless send_soap opts[:control], namespace, :DeletePortMapping, <<EOF
<NewRemoteHost></NewRemoteHost>
<NewExternalPort>#{opts[:external_port]}</NewExternalPort>
<NewProtocol>#{opts[:protocol]}</NewProtocol>
EOF

    Log.info "UPnP router #{URI.parse(opts[:control]).host} is no longer forwarding #{opts[:external_port]}"
    return true
  end


  def self.send_soap url, ns, method, content
    ns = "urn:schemas-upnp-org:#{ns}"
    uri = URI.parse url
    body = <<EOF

<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:#{method} xmlns:u="#{ns}">
#{content}
</u:#{method}>
</s:Body>
</s:Envelope>
EOF

    headers = {
      KeepCase.new("Host") => "#{uri.host}:#{uri.port}",
      KeepCase.new("Content-Length") => body.length.to_s,
      KeepCase.new("Content-Type") => 'text/xml; charset="utf-8"',
      KeepCase.new("SOAPAction") => %{"#{ns}##{method}"},
    }

    response = gunlock do
      Net::HTTP.start( uri.host, uri.port ) do |http|
        http.post uri.request_uri, body, headers
      end
    end
    if !response.is_a? Net::HTTPSuccess
      error = REXML::Document.new response.body
      error.elements.each( "//errorDescription" ) do |err|
        Log.warn "UPnP warning: Failure for #{uri.host}: #{err.text}"
      end
      return nil
    end
    return response.body
  end
end

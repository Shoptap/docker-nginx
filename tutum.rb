require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'tutum'
require 'erb'
require 'logger'
require 'uri'

if !ENV['TUTUM_AUTH']
  puts "Nginx doesn't have access to Tutum API - you might want to give an API role to this service for automatic backend reconfiguration"
  exit 1
end

RESTRICT_MODE = (ENV['RESTRICT_MODE'] || :none).to_sym
# Retrieve the node's fqdn.
THIS_NODE = ENV['TUTUM_NODE_FQDN']
THIS_SERVICE_URI = ENV['TUTUM_SERVICE_API_URI']

$stdout.sync = true
CLIENT_URL = URI.escape("wss://stream.tutum.co/v1/events?auth=#{ENV['TUTUM_AUTH']}")

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO

# PATCH
class Tutum
  attr_reader :tutum_auth
  def initialize(options = {})
    @tutum_auth = options[:tutum_auth]
  end
  def headers
    {
      'Authorization' => @tutum_auth,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
  end
end


class NginxConf

  TEMPLATE = File.open("./nginx.conf.erb", "r").read

  def initialize()
    @renderer = ERB.new(TEMPLATE)
  end

  def write(services, file)
    @services = services

    @services.each do |service|
      LOGGER.info service.name + ': ' + service.container_ips.inspect
    end

    result = @renderer.result(binding) #rescue nil
    if result
      File.open(file, "w+") do |f|
        f.write(result)
      end
    end
  end

end


class Container
  attr_reader :id, :attributes

  def initialize(attributes)
    @id = attributes['uuid']
    @attributes = attributes
  end

  def ip
    attributes['private_ip']
  end

  def host
    attributes['container_envvars'].find {|e| e['key'] == 'VIRTUAL_HOST' }['value']
  end

  def ssl?
    !!attributes['container_envvars'].find {|e| e['key'] == 'FORCE_SSL' }['value']
  end

  def node
    attributes['container_envvars'].find {|e| e['key'] == 'TUTUM_NODE_FQDN'}['value']
  end

  def running?
    ['Starting', 'Running'].include?(attributes['state'])
  end

end

class Service
  attr_reader :id, :attributes, :session, :name
  def initialize(attributes, session)
    @id = attributes['uuid']
    @name = attributes['name']
    @attributes = attributes
    @session = session
  end

  def name
    attributes['name']
  end

  def port_types
    @port_types ||= containers.first.attributes['container_ports'].map {|p| p['port_name']} rescue nil
  end
  
  def port_inner
    @port_inner ||= containers.first.attributes['container_ports'].map {|p| p['inner_port'].to_i} rescue nil
  end

  def container_ips
    @container_ips ||= containers.map {|c| c.ip if running? }.sort
  end

  def include?(mode, mode_options = {})
    @mode, @mode_options = mode, mode_options
    reload!
    if rightStack? && notSelf? && running?
      reload!
      containers? && http? 
    else
      false
    end
  end

  def http?
    (port_types && (port_types & ['http', 'https']).count > 0) || (port_inner && (port_inner & [3000]).count > 0)
  end

  def host
    @host ||= containers.first.host rescue nil
  end

  def ssl?
    @ssl ||= containers.first.ssl? rescue nil
  end

  def running?
    @state ||= begin
      ['Running', 'Partly running'].include?(attributes['state'])
    end
  end

  def rightStack?
    @mode_options[:my_stack] == attributes['stack']
  end
  
  def notSelf?
    @mode_options[:my_uuid] != attributes['uuid']
  end

  def containers?
    containers.count > 0
  end


  def containers
    @containers ||= begin
      attributes['containers'].map do |container_url|
        id = container_url.split("/").last
        container = Container.new(session.containers.get(id))
        if include_container? container
          container
        else
          nil
        end
      end.compact
    end
  end

  def reload!
    @attributes = session.services.get(id)
  end

  def include_container?(container)
    case @mode
    when :node
      @mode_options[:node] == container.node
    when :node_link
      @mode_options[:node] == container.node && @mode_options[:links].include?(attributes['resource_uri'])
    when :link
      @mode_options[:links].include?(attributes['resource_uri'])
    when :region
      @mode_options[:region_map][@mode_options[:node]] == @mode_options[:region_map][container.node]
    else
      true
    end
  end

end

class HttpServices

  def self.reload!
    LOGGER.info 'Reloding Nginx...'
    EventMachine.system("nginx -s reload")
  end

  attr_reader :session, :mode, :node
  def initialize(tutum_auth, mode = :none, node = nil, service = nil)
    @session = Tutum.new(tutum_auth: tutum_auth)
    @mode = mode
    @node = node
    @this_service_id = service
    @services = get_services
  end

  def write_conf(file_path)
    @nginx_conf ||= NginxConf.new()
    @nginx_conf.write(@services, file_path)
    LOGGER.info 'Writing new nginx config'
    self
  end

  private

  def this_service    
    @_this_service ||= begin
      LOGGER.info('My URI: ' + @this_service_id)
      sess = @session.services.list({})['objects'].detect{|w| w['resource_uri'] == @this_service_id}
      session.services.get(sess['uuid'])
    end
  end
  
  def get_services
    me = this_service
    my_stack = me['stack']
    links = me['linked_to_service'].map { |x| x['to_service'] } if me['linked_to_service']
    
    services = []
    services_list.each do |service|
      if service.include? mode, node: node, region_map: region_map, my_stack: my_stack, links: links, my_uuid: this_service['uuid']
        services << service
      end
    end
    services
  end

  def services_list(filters = {})
    session.services.list(filters)['objects'].map {|data| Service.new(data, session) }
  end

  def get_nodes(filters = {})
    session.nodes.list(filters)['objects']
  end

  def region_map
    @region_map ||= begin
      if mode == :region
        get_nodes.map {
            # Map the fqdn to the region. For 'own nodes', region is nil.
            |node| { node['external_fqdn'] => node['region'] }
        }.reduce({}) {
            |h,pairs| pairs.each {|k,v| h[k] = v }; h
        }
      else
        {}
      end
    end
  end

end

module NginxConfHandler
  def file_modified
    @timer ||= EventMachine::Timer.new(0)
    @timer.cancel
    @timer = EventMachine::Timer.new(3) do
      HttpServices.reload!
    end
  end
end

EventMachine.kqueue = true if EventMachine.kqueue?

EM.run {
  @services_changing = []
  @services_changed = false
  @shutting_down = false
  @timer = EventMachine::Timer.new(0)

  def init_nginx_config
    LOGGER.info 'Init Nginx config'
    LOGGER.info 'Restriction mode: ' + RESTRICT_MODE.to_s
    HttpServices.new(ENV['TUTUM_AUTH'], RESTRICT_MODE, THIS_NODE, THIS_SERVICE_URI).write_conf(ENV['NGINX_DEFAULT_CONF'])
    HttpServices.reload!
  end

  def signal_handler(signal)
    # In rare cases the signal comes multiple times. If we're already shutting down ignore this.
    unless @shutting_down
      # We can't use the logger inside a trap, stdout must be enough.
      puts "Signal #{signal} received. Shutting down."

      @shutting_down = true

      EventMachine.stop
    end
  end

  def connection
    LOGGER.info "Connecting to #{CLIENT_URL}"
    ws = Faye::WebSocket::Client.new(CLIENT_URL, nil, ping: 240)

    ws.on :open do |event|
      LOGGER.info "Connected!"
      if @services_changing.count > 0
        @services_changing = []
        @services_changed = false
        @timer.cancel
        @timer = EventMachine::Timer.new(0)
        init_nginx_config
      end
    end

    ws.on :message do |event|
      data = JSON.parse(event.data)

      trigger = false
      if data['type'] == 'service'
        trigger = true

        case data['state']
        when 'Scaling', 'Redeploying', 'Stopping', 'Starting', 'Terminating'
          LOGGER.info "Service: #{data['uuid']} is #{data['state']}..."
          @timer.cancel # cancel any conf writes
          @services_changing << data['uuid']
        when 'Running', 'Stopped', 'Not running', 'Terminated'
          if @services_changing.count > 0
            LOGGER.info "Service: #{data['uuid']} is #{data['state']}!"
            @services_changing.shift
            @timer.cancel # cancel any conf writes
            @services_changed = true
          end
        end
      end

      if data['state'] == 'Success' && data['parents'] && data['parents'].include?(THIS_SERVICE_URI)
        LOGGER.info "Attribute change on this service. Most likely link change."
        @services_changing.shift
        @timer.cancel # cancel any conf writes
        @services_changed = true
        trigger = true
      end

      if trigger && @services_changed && @services_changing == []
        LOGGER.info "Services changed - Rewrite Nginx config"
        @services_changed = false
        @timer.cancel
        @timer = EventMachine::Timer.new(5) do
          HttpServices.new(ENV['TUTUM_AUTH'], RESTRICT_MODE, THIS_NODE, THIS_SERVICE_URI).write_conf(ENV['NGINX_DEFAULT_CONF'])
        end

      end
    end

    ws.on(:error) do |event|
      LOGGER.info JSON.parse(event.data).inspect
    end

    ws.on(:close) do |event|
      unless @shutting_down
        LOGGER.info 'Connection closed! ... Restarting connection'

        # restart the connection
        connection
      else
        LOGGER.info 'Connection closed!'
      end
    end

  end

  init_nginx_config
  Signal.trap('INT')  { signal_handler('INT') }
  Signal.trap('TERM') { signal_handler('TERM') }
  EventMachine.watch_file(ENV['NGINX_DEFAULT_CONF'], NginxConfHandler)
  connection
}

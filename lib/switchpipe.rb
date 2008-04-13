# The gutty-wutts of the SwitchPipe operation..

require 'rubygems'
require 'eventmachine'
require 'yaml'
require 'open4'
require 'socket'
require 'logger'

module SwitchPipe
  # Set up some constants
  HOME_FOLDER       = File.join(Dir.pwd, File.dirname(__FILE__), '..')
  CONFIG_FOLDER     = File.join(HOME_FOLDER, 'apps')
  LOG_FOLDER        = File.join(HOME_FOLDER, 'log')
  ENVIRONMENT       = :development  # or :production
  VERSION           = "1.05"
  LOG               = Logger.new(File.join(LOG_FOLDER, ENVIRONMENT.to_s + '.log'), 'daily')
  LOG.sev_threshold = ENVIRONMENT == :development ? Logger::DEBUG : Logger::INFO


  # App: Representation of a single "backend application" which can then be present in multiple instances
  # Instances are not represented by a class at this point
  class App
    # Various attributes related to an application
    attr_accessor :name, :cmd, :path, :instances, :host, :single_threaded, :timeout, :min_instances, :max_instances, :updated_at, :user, :group, :hostnames, :socket_type
    
    # Set up storage for the list of apps, hostnames, and the list of PIDs of dead child / instance processes
    @@apps = {}
    @@hostnames = {}
    @@dead_pids = {}
    
    # Return the hash containing the information for each back end application
    def self.apps
      @@apps
    end
    
    # Print the list of running apps and the status of their instances
    def self.show_status
      @@apps.sort{ |a,b| a.to_s <=> b.to_s }.each do |k, v|
        puts "   #{sprintf("%20s", k)} (#{v.instances.size} inst.) (#{v.instances.collect{ |i| "#{i[:pid]}/#{i[:status]}:#{i[:port]}" }.join(' ')})"
      end
      puts
    end
    
    # Keep the hostnames hash up to date with the latest hostname<=>app links
    def self.maintain_hostnames
      # Associate apps with hostnames
      @@apps.each do |app_name, app|
        [*app.hostnames].each do |hostname|
          @@hostnames[hostname.downcase] = app
        end if app.hostnames
      end

      # Delete hostnames for apps that don't exist anymore
      @@hostnames.delete_if { |hostname, app| !@@apps.keys.include?(app.name) }
    end
    
    # Make sure any minimum number of instances for applications are loaded
    def self.start_necessary_instances
      @@apps.each do |app_name, app|
        (app.min_instances - app.instances.size).times { app.launch_new_instance }
      end
    end
    
    # Try to "safely kill" an instance of a backend application, firstly by closing its
    # IO handles, then sending an INT signal.
    def self.safe_kill(i)
      LOG.debug "Killing #{i[:pid]}"
      
      # As we try not to run background / daemonized apps, closing the handles often has the right effect..
      begin
        i[:stdin].close && i[:stdout].close && i[:stderr].close
      rescue
      end
      
      # For good measure, we'll explicitly kill the child process
      Process.kill("INT", i[:pid])    # Some handle TERM better, but we'll stick to the basics for now.. maybe make it customizable in future?
      
      # Add the PID to an array so we can "wait" on it later to avoid zombies OoooOOooooOOOooooo!!
      @@dead_pids[i[:pid]] = 0
      
      # Make sure the port is marked as no longer being in use
      Config.ports[i[:port]] = nil
      
      # Erase the instance from all known records for this app
      i[:app].instances.map! { |item| item && item[:pid] == i[:pid] ? nil : item }
    end
    
    # Go through all the instances of the back end apps and "clean them up", namely wait for
    # child processes to tidy themselves up, and kill instances that are past their sell-by date!
    def self.clean_up      
      # Catch up with all the dead processes to clear them off the process table
      @@dead_pids.each do |pid, attempts|
        LOG.debug "Cleaning up after #{pid}"
        @@dead_pids[pid] += 1
        status = Process.wait(pid, Process::WNOHANG)
        
        # If a process doesn't get the hint after the first INT, and two waits, move on to a KILL!
        if status.nil? && attempts > 1
          LOG.debug "Hard kill on #{pid}!"
          Process.kill("KILL", pid)      # Desperate measures!
        elsif !status.nil?
          # We finally successfully waited for a child process to die, so let's get rid of it for good
          @@dead_pids.delete(pid)
        end
      end
      
      # Go through each instance of each app and start to kill those that are out of date, that have
      # been "busy" for too long, or which are otherwise broken
      @@apps.values.each do |app|
        app.instances.each do |i|          
          next unless i[:last_request]

          # Is this instance a) not been used for a certain number of seconds, b) broken, c) busy for a certain number of seconds * 2?
          # If so, begin the cull!
          
          # Yes, this is a weird construction, but it's to make it a bit easier to read..
          # If the time of the last request is over app.timeout seconds ago AND the app is not currently busy AND there are more instances than needed.. kill!
          if ((Time.now.to_i - i[:last_request] > app.timeout) && (i[:status] != :busy) && (app.instances.size > app.min_instances))
            safe_kill(i) 
          
          # If the backend instance is marked as broken.. kill!
          elsif (i[:status] == :broken)
            safe_kill(i)
            
          # If the backend instance is busy but hasn't served a request within the timeout phase, plus a 10 second allowance.. kill!
          elsif ((Time.now.to_i - i[:last_request] > (app.timeout + 10)) && (i[:status] == :busy))
            safe_kill(i)
            
          # If the backend process has been running for an hour, kill it just to keep things clean..
          elsif (Time.now.to_i - i[:start_time] > 3600)
            safe_kill(i)
          end
        end
        app.instances.compact!
      end
    end
    
    # Clean out the IO buffers being used for output from the backend processes
    # If you don't do this, they can fail to work once the buffers are full (16384 bytes, commonly)
    def self.drain_buffers
      @@apps.values.each do |app|
        app.instances.each do |i|
          # Clear any IO buffers for each app, first the standard out, then the standard error
          i[:stdout].readpartial(5000000) if IO.select([i[:stdout]], nil, nil, 0.001) rescue nil
          i[:stderr].readpartial(5000000) if IO.select([i[:stderr]], nil, nil, 0.001) rescue nil
        end
      end
    end
    
    # Terminate all running instances of all apps, and do it fast!
    def self.terminate_all
      puts "\nHarshly killing every backend instance"
      LOG.info "Dying due to signal..!"
      
      @@apps.each do |k, v|
        v.instances.each do |i|
          2.times { Process.kill("KILL", i[:pid]) rescue nil }
          
          # Not my proudest moment..
          10.times { Process.wait(i[:pid], Process::WNOHANG) rescue nil }
        end
      end
    end
    
    # Terminate all instances of a specific backend application
    def terminate_instances
      LOG.debug "Terminate instances run.. #{self.instances.collect{|a| a[:pid] }.join(' ')} should all go.." if ENVIRONMENT == :development
      self.instances.each do |i|
        App.safe_kill(i)
      end
      self.instances.compact!
    end
    
    # Remove an app and kill all its instances
    def remove
      terminate_instances
      @@apps.delete_if { |k, v| v.name == name }
    end
    
    # Kicks things off by launching an instance if there isn't already one or more
    def run
      launch_new_instance if instances.empty?
    end
    
    # Launches a new instance of a back end application
    def launch_new_instance      
      instance = {}
            
      # Get the instance in to the main instance store early to avoid locking issues
      instances << instance
      
      # Find a port to use and claim it
      port = Config.next_available_port
      Config.ports[port] = self
      
      # Substitute in dynamic parts of the command to execute
      cmd_line = cmd.gsub(/\[\[PORT\]\]/, port.to_s)
      cmd_line.gsub!(/\[\[USER\]\]/, user.to_s)
      cmd_line.gsub!(/\[\[GROUP\]\]/, group.to_s)
                  
      # Temporarily change to the directory of the backend app and execute the relevant command, passing the PID
      # and all relevant file handles back to us here
      #
      # TODO: Look into suEXEC type mechanisms and/or sudo to make child apps run as different users
      Thread.exclusive { Dir.chdir(path) { instance[:pid], instance[:stdin], instance[:stdout], instance[:stderr] = Open4::popen4(*cmd_line.split(/\s+/)) } }
      LOG.debug "Running #{cmd_line}"
      LOG.info "Launching instance of '#{name}'"
      
      # Set the start time of the instance, the port, host, status, and other crap
      instance[:start_time] = Time.now.to_i
      instance[:port] = port
      instance[:host] = host
      instance[:status] = :loading
      instance[:last_request] = Time.now.to_i + 5
      instance[:app] = self

      # Try to connect to the back end application we've just launched so we know when it's up
      100.times do |i|
        sock = case socket_type
          when :unix
            UNIXSocket.new("/tmp/switchpipe-#{port}.sock")
          when :tcp
            TCPSocket.new(host, port)
        end rescue nil

        if sock != nil
          # If the service is up, close our test socket, and mark this instance as ready to roll..
          sock.close
          instance[:status] = :ready
          
          # And get outta here!
          break
        end
        sleep 0.1
        if i == 99
          # If we made it 10 seconds without the app coming up, we might as well give up
          # NOTE: Might need to increase this timeout to several minutes when Rails 3.0 hits the streets^H^H^H^H^H^H^H^H^H^H^H...
          instance[:status] = :broken
          sock.close rescue nil
          break
        end
      end
    end
    
    # Return the next available instance of the app to call
    def next_available_instance
      return nil if instances.empty?
      
      # Make sure to go through instances in order so as to make sure the total number of instances used
      # is as small as possible.
      instance_position = 0
      3500.times do
        random_instance = instances[instance_position]
        
        # Avoid issues where other threads are messing around with which instances are alive and which aren't
        instance_position = 0 and next unless random_instance
        
        if random_instance[:status] == :ready || (!single_threaded && random_instance[:status] == :busy)
          random_instance[:status] = :busy
          return random_instance 
        end
        
        # Increase the position, but make sure to loop back around when necessary!
        instance_position = (instance_position + 1) % instances.size
        
        # If there's still room for more instances, launch a new one while we're waiting..
        launch_new_instance if instances.size < max_instances
        
        # There weren't any instances ready to roll, so we'll wait a little and try again
        sleep 0.002
      end
      
      nil
    end
    
    # Update the configuration for an application based on the details provided in its configuration file
    def update_configuration(config)
      terminate_instances if instances && !instances.empty?
      
      # Set all the options and settings for the app
      if config['type']
        if config['socket_type'] && config['socket_type'].downcase == 'unix' && config['user'] && config['group']
          shortcuts = { 
            :thin => "thin --socket /tmp/switchpipe-[[PORT]].sock -u [[USER]] -g [[GROUP]] -e production start"
          }
        elsif config['user'] && config['group']
          shortcuts = { 
            :mongrel_rails => "mongrel_rails start -p [[PORT]] -e production --user [[USER]] --group [[GROUP]]",
            :mongrel => "mongrel_rails start -p [[PORT]] -e production --user [[USER]] --group [[GROUP]]",
            :thin => "thin -p [[PORT]] -u [[USER]] -g [[GROUP]] -e production start",
            :ebb => "ebb_rails start -e production -p [[PORT]]"
          }
        else
          shortcuts = {
            :mongrel_rails => "mongrel_rails start -p [[PORT]] -e production",
            :mongrel => "mongrel_rails start -p [[PORT]] -e production",
            :thin => "thin -p [[PORT]] -e production start",
            :ebb => "ebb_rails start -e production -p [[PORT]]"
          }
        end
        self.cmd = shortcuts[config['type'].to_sym] rescue nil
      else
        self.cmd = config['cmd']
      end
      
      # No command? No dice
      unless self.cmd
        self.instances = []
        return
      end
      
      # Is the path an absolute or relative one? Deal accordingly
      if config['path'] =~ /^\//
        self.path = config['path']
      else
        self.path = File.join(HOME_FOLDER, config['path'])
      end
      
      # No running instances so far!
      self.instances = []
      
      # Set the time file load time to use for future loading opportunities
      self.updated_at = config['updated_at']
      
      # By default, the back end app will be running on localhost
      self.host = config['host'] || "127.0.0.1"
      
      # Store which hostnames can be used to access the app
      self.hostnames = config['hostname']
      
      # By default, set a timeout of 5 minutes for back end apps
      self.timeout = config['timeout'] || 300
      
      # By default, only allow one instance per app
      self.max_instances = config['max_instances'] || 1
      
      # By deafult, have no minimum instances requirements
      self.min_instances = config['min_instances'] || 0
      
      # By default, don't run as any particular user (same as current user really)
      self.user = config['user']
      self.group = config['group']
      
      # By default use TCP sockets (UNIX sockets are a VERY alpha feature at the moment)
      self.socket_type = (config['socket_type'] || 'tcp').downcase.to_sym
      
      # By default, assume back end instances are single threaded apps (such as Rails apps)
      if config['single_threaded'] == false
        self.single_threaded = false
      else
        self.single_threaded = true
      end
    end
    
    # Set up an app, deleting any existing one with the same name
    def initialize(name, config)
      @@apps[name.to_sym] = self
      self.name = name.to_sym
      update_configuration(config)
    end
    
    # Return an app in an easy way.. App['app-name']
    def self.[](app_name)
      @@apps[app_name.to_sym]
    end
    
    # Return an app matching on the path
    def self.find_by_path(path)
      # NOTE: We need to ignore when we can't symbolize the path, as
      #       app_from_path() returns FALSE in some cases
      @@apps[path.to_sym] if path.respond_to?(:to_sym)
    end
    
    # Return an app matching on the hostname    
    def self.find_by_hostname(hostname)
      # Find the app by its hostname
      # TODO: Change the way this works so to avoid issues relating to finding subdomains when we don't want to (for now it's a cute trick))
      @@hostnames.find { |h, app| hostname =~ Regexp.new(h) }[1]
    rescue
      nil      
    end
  end
  

  # Connection: EventMachine delivers data to an instance of this class.
  # We handle the collective details surrounding individual requests here,
  # and buffer the request data as it arrives, before processing it.
  class Connection < EventMachine::Connection
    attr_accessor :app
    
    def post_init
      @request = Request.new
      @data_buffer = ""
      @header_length = nil
    end
    
    # Data has been received! Deal with it..    
    def receive_data(data)
      @data_buffer << data
  
      # If the data buffer is getting too long and still no HTTP header has come in, close the connection
      if (@data_buffer.length > 10000000)
        send_data "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 16\r\nContent-Type: text/plain\r\n\r\nToo many data"
        close_connection_after_writing
        return
      end
  
      # Is the data a full HTTP request yet? If so, process it..
      # (note: this isn't true HTTP parsing, of course!)
      if (@data_buffer =~ /HTTP/i && @data_buffer =~ /\r\n\r\n/) || (@process_body && (@data_buffer.length >= @header_length + @request.headers['content-length'][1].to_i))
        @request.data = @data_buffer
        
        # Just because we have the HTTP request / header, doesn't mean we have all the BODY.. if a body is present, read that too..!        
        if @request.headers['content-length'] && @request.headers['content-length'][1].to_i > 0          
          # Have we got all of the content that's coming our way? If not, get outta here!
          return unless @data_buffer.length >= @request.headers_length + @request.headers['content-length'][1].to_i
        end
        
        process
      end

      # If data's still coming in but no HTTP header has been found within 15 seconds, close the connection
      raise if (@request.start_time < (Time.now.to_i - 15))

    rescue
      # When all else fails..
      LOG.error "Caught #{$!} - close_connection called"
      close_connection
    end

    # Actually process a request
    def process
      # Define "before" and "after" functions, so that we can do all this in a semi-event driven manner and play nice with the threading..
      before = lambda do 
        # First, figure out which app is being accessed
        found_by = :hostname
        app = App.find_by_hostname(@request.hostname)
        unless app
          app = App.find_by_path(@request.app_from_path)
          found_by = :path
        end
        
        LOG.debug('Failed to find app') unless app 
        return '' unless app

        # Log the request
        LOG.info "Request: #{app.name}"

        # Make sure at least one instance is running, this might be the first time out!
        app.run

        # Grab an available instance of the app
        instance = app.next_available_instance
        return '' unless instance
        
        # Open a connection to the backend instance
        sock = case app.socket_type
          when :unix
            UNIXSocket.new("/tmp/switchpipe-#{instance[:port]}.sock")
          when :tcp
            TCPSocket.new(instance[:host], instance[:port])
        end rescue nil
        
        # If the backend isn't responding, let's just panic and get outta here..
        unless sock
          send_data "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\nContent-Length: 27\r\nContent-Type: text/plain\r\n\r\nBackend application failure"
          close_connection_after_writing
          return
        end

        sock.sync = true
        
        # We can't deal with keep-alive arrangements yet, so make sure the connection will close
        # after each request!
        # TODO: Look into dealing with keep-alives with a timeout of some sort if no new requests appear..
        # Take care not to ignore backend apps that fail to respect keep-alive, however!
        @request.headers['connection'] = ['Connection', 'close']
        
        # Write out the HTTP request, with some minor changes (removal of the app identifier path, for one)
        if found_by == :path
          sock.write @request.request_line_without_app + "\r\n" + @request.header_string + "\r\n\r\n"
        else
          sock.write @request.request_line + "\r\n" + @request.header_string + "\r\n\r\n"          
        end
        
        # Write out the HTTP message body, if any
        sock.write @request.body if @request.body && !@request.body.empty?
        sock.flush
        
        instance[:last_request] = Time.now.to_i
        
        # Read back the data from the app
        resp = sock.read
        sock.close
                
        # Update some information about this particular instance for good housekeeping..
        instance[:status] = :ready
        
        # Return the data, ready to go to the callback
        resp
      end
      
      # The "after" function is pretty simple. It just returns data to the client
      after = lambda do |resp|
        return unless resp
        send_data resp
        close_connection_after_writing
      end
      
      # Let EventMachine turn this whole request process into a threaded doo-hickey
      # so that busted back end apps don't screw us over.. get rid of the blocking
      # side of things, eh?
      EventMachine.defer(before, after)
    end
  end
  
  # Request: Represents an incoming request, and abstracts away the various things we
  # do to process the elements involved in that request
  #
  # TODO: This class does not parse HTTP in any approved sort of way, it's totally pragmatic for now.
  # We can move to a proper HTTP parser later.. (perhaps Mongrel's - doing a Thin!)
  #
  # TODO: A lot of SwitchPipe's loss of speed is in this class, I bet. There are probably
  # quite a few ways to speed things up here.
  class Request
    attr_reader :data, :headers, :start_time
    
    def initialize
      @start_time = Time.now.to_i
    end
    
    # Stores data in the request object, and set the headers up at the same time
    def data=(content)
      @data = content
      @headers = {}
      
      # Believe it or not, this is faster with the unnecessary "each" than without..
      content.slice(0, content.index("\r\n\r\n") + 1).scan(/^(\S+)\:\s+(.*?)$/).each { |a| @headers[a[0].downcase] = [a[0], a[1].chomp] }
    end
    
    # Returns the hostname from the Host header, if any
    def hostname
      @headers['host'][1] rescue nil
    end
        
    # Returns the request headers as a string ready for use over HTTP
    def header_string
      self.headers.collect { |k,v| "#{v[0]}: #{v[1]}" }.join("\r\n")
    end
    
    # Returns the first line of the HTTP request
    def request_line
      @data.slice(0, @data.index("\r\n"))
    end
    
    # Returns the length of the original set of headers
    def headers_length
      @headers_length ||= (data.index("\r\n\r\n") + 1) rescue nil
    end
    
    # Returns the message body, if any
    def body
      data[/\r\n\r\n.*/m][4..-1]
    end
    
    # Returns the path requested in the HTTP request
    def path
      request_line.match(/\/(\S+)/)[1] rescue nil
    end
    
    # Returns the first directory name in the path requested. This is the "application name" in SwitchPipe-land.
    def app_from_path
      path.include?('/') ? path.split('/').first : path
    end
    
    # Returns the actual location part of the path, as understood by SwitchPipe at least.
    def path_remainder
      "/#{path.match(/[^\/]+\/(.*)/)[1]}" rescue '/'
    end
    
    # Returns the HTTP verb used (GET, POST, PUT, etc)
    def verb
      request_line.match(/^(\w+)/)[1] rescue nil
    end
    
    # Returns whatever comes after the HTTP verb and path, typically the HTTP version (HTTP/1.1, etc)
    def trimmings
      request_line.match(/\s+(\S+)$/)[1] rescue nil
    end
    
    # Builds the request line of an HTTP request without the included app name
    # Example: /appname/test/blah.html .. becomes: /test/blah.html
    def request_line_without_app
      "#{verb} #{path_remainder} #{trimmings}"
    end
  end
  
  # Generic configuration class, placeholder for all manner of scrummy data
  class Config
    @@ports = {}
    
    def self.init      
      # Load the main configuration file (config.yml in SwitchPipe' home folder)
      @main_configuration = YAML.load_file(File.join(HOME_FOLDER, 'config.yml')) rescue nil
      
      # Get the configurations for the backend apps loaded
      load_app_configurations
      
      # Set up the hostname store
      App.maintain_hostnames
    end
    
    def self.load_app_configurations
      Dir[CONFIG_FOLDER + "/*.yml"].each do |f|
        load_app_configuration(f)
      end
    end
    
    def self.load_app_configuration(f)
      app_name = File.basename(f).sub(/\.\w+$/, '')
      
      # Load the app's configuration from its YAML file and set the updated_at time
      app_config = YAML.load_file(f) rescue nil
      app_config['updated_at'] = File.mtime(f).to_i
      
      # The app is already loaded, see whether we need to continue or not..
      if App[app_name]
        return unless File.mtime(f).to_i > App[app_name].updated_at
        LOG.info "Reloading '#{app_name}' due to config file update"
        App[app_name].update_configuration(app_config)
      else
        # Create the app object
        App.new(app_name, app_config)
        
        LOG.info "Loading '#{app_name}'"
      end
    end
    
    def self.maintain_configurations
      load_app_configurations
      remove_deleted_apps
      App.maintain_hostnames
    end
    
    def self.remove_deleted_apps
      App.apps.each do |app_name, app|
        unless File.exist?(CONFIG_FOLDER + "/#{app.name}.yml")
          app.remove 
          LOG.info "Removed '#{app.name}' due to config file removal"
        end
      end
    end
    
    def self.[](arg)
      return @main_configuration[arg]
    end
    
    def self.ports=(arg)
      @@ports = arg
    end
    
    def self.ports
      @@ports
    end
    
    # Find a port for a new instance to use
    def self.next_available_port
      loop do
        port_num = rand(Config['backend_port_end'] - Config['backend_port_start'] + 1) + Config['backend_port_start']
        return port_num if ports[port_num].nil?
      end
      
      raise
    end

  end
  
  # Class representing the server side of SwitchPipe
  class Server
    def initialize
      Config.init
      
      LOG.info "Started"
      
      @host = Config['host'] || "127.0.0.1"
      @port = Config['port'] || 3000
      
      trap('INT')  { stop_everything }
			trap('TERM') { stop_everything }
    end
    
    def stop_everything
      App.terminate_all
      LOG.close
      EventMachine.stop_event_loop
    end
        
    def run
      # For nicer times on Linux
      # --- actually, epoll on Linux makes SwitchPipe run FAR slower (10x slower) for some reason so this is commented out
      # --- I have asked the EventMachine people if they have any ideas..
      #     (Update: epoll has big issues with Ruby threading, the Connection#process method would need to be written to
      #              not use 'defer' to resolve this..)
      # EventMachine.epoll
      
      # Main set up stage for the EventMachine server
			EventMachine.run do
				begin
					EventMachine.start_server(@host, @port, Connection) do |connection|
					  connection.comm_inactivity_timeout = Config['inactivity_timeout'] || 30
					end
					
					EventMachine.set_effective_user(Config['user']) if Config['user']
					
					# Set up period housekeeping duties, such as showing the status of SwitchPipe and cleaning up child processes
					EventMachine::add_periodic_timer(Config['status_update'] || 5) { App.show_status } if ENVIRONMENT == :development
					EventMachine::add_periodic_timer(3) { App.clean_up }
					EventMachine::add_periodic_timer(5) { Config.maintain_configurations; App.start_necessary_instances }
					EventMachine::add_periodic_timer(1) { App.drain_buffers }	
					
					App.start_necessary_instances
				end
			end
    end
    
    def addr
      "#{@host}:#{@port}"
    end
  end
end
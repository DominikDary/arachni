=begin
  $Id$

                  Arachni
  Copyright (c) 2010 Anastasios Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LINCENSE file for details)

=end


require 'rubygems'
require $runtime_args['dir']['lib'] + 'exceptions'
require $runtime_args['dir']['lib'] + 'ui/cli/output'
require $runtime_args['dir']['lib'] + 'spider'
require $runtime_args['dir']['lib'] + 'analyzer'
require $runtime_args['dir']['lib'] + 'vulnerability'
require $runtime_args['dir']['lib'] + 'module/http'
require $runtime_args['dir']['lib'] + 'module'
require $runtime_args['dir']['lib'] + 'module_registrar'
require $runtime_args['dir']['lib'] + 'module_registry'
require 'ap'
require 'pp'


module Arachni

#
# Arachni::Framework class<br/>
# The Framework class ties together all the components.
#
# It should be wrapped by a UI class.
#
# @author: Zapotek <zapotek@segfault.gr> <br/>
# @version: 0.1-planning
#
class Framework

    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include Arachni::UI::Output
    
    #
    # Instance options
    #
    # @return [Hash]
    #
    attr_reader :opts

    #
    # Initializes all the system components.
    #
    # @param    [Hash]    system opts
    #
    def initialize( opts )
        @opts = Hash.new
        
        @opts = @opts.merge( opts )
            
        @modreg = Arachni::ModuleRegistry.new( @opts['dir']['modules'] )

        parse_opts( )

        @spider   = Arachni::Spider.new( @opts )
        @analyzer = Arachni::Analyzer.new( @opts )
        
        $_interrupted = false
        trap( "INT" ) { $_interrupted = true }

    end

    #
    # Gets the results of the audit
    #
    # @return    [Array<Vulnerability>]
    #
    def get_results
        Arachni::ModuleRegistry.get_results( )
    end

    #
    # Runs the system
    #
    # It parses the instanse options and runs the audit
    #
    # @return    [Array<Vulnerability>] the results of the audit
    #
    def run
        
        # pass any exceptions to the UI
        begin
            validate_opts
        rescue
            raise
        end
        
        audit( )
    end
    
    #
    # Audits the site.
    #
    # Runs the spider and loaded modules.
    #
    # @return    [Array<Vulnerability>] the results of the audit
    #
    def audit

        skip_to_audit = false

        site_structure = Hash.new
        mods_run_last_data = []

        sitemap = @spider.run {
            | url, html, headers |

            structure = site_structure[url] =
                @analyzer.run( url, html, headers ).clone

            page_data = {
                'url'        => { 'href' => url,
                'vars'       => @analyzer.get_link_vars( url )
                },
                'html'       => html,
                'headers'    => headers,
                'cookies' => @opts[:cookies]
            }

            if !@opts[:mods_run_last]
                run_mods( page_data, site_structure[url] )
            else

                if $_interrupted == true
                    print_line
                    print_info( 'Site analysis was interrupted,' +
                    ' do you want to audit the analyzed pages?' )

                    print_info( 'Audit?(\'y\' to audit, \'n\' to exit)(y/n)' )

                    if gets[0] == 'y'
                        skip_to_audit = true
                    else
                        print_info( 'Exiting...' )
                        exit 0
                    end

                end
                
                mods_run_last_data.push( { page_data => site_structure[url]} )
                    
            end

            if skip_to_audit == true
                print_info( 'Skipping to audit.' )
                print_line
                $_interrupted = false
                break
            end

        }

        if @opts[:mods_run_last]
            mods_run_last_data.each {
                |data|
                run_mods( data.keys[0], data.values[0] )
            }
        end

        get_results
    end

    #
    # Returns an array of all loaded modules
    #
    # @return    [Array<Class>]
    #
    def ls_loaded
        @modreg.ls_loaded( )
    end

    #
    # Loads modules
    #
    # @param [Array]    Array of modules to load
    #
    def mod_load( mods = ['*'] )
        #
        # Check the validity of user provided module names
        #
        mods.each {
            |mod_name|
            
            # if the mod name is '*' load all modules
            if mod_name == '*'
                @modreg.ls_available(  ).keys.each {
                    |mod|
                    @modreg.mod_load( mod )
                }
                break
            end
                
            if( !@modreg.ls_available(  )[mod_name] )
                raise( Arachni::Exceptions::ModNotFound,
                    "Error: Module #{mod_name} wasn't found." )
            end
    
            # load the module
            @modreg.mod_load( mod_name )
        }
    end

    #
    # Returns an array of hashes with information
    # about all available modules
    #
    # @return    [Array<Hash>]
    #
    def lsmod
        
        i = 0
        mod_info = []
        
        @modreg.ls_available().each_pair {
            |mod_name, path|
    
            @modreg.mod_load( mod_name )
    
            info = @modreg.mod_info( i )
    
            info["mod_name"]    = mod_name
            info["Name"]        = info["Name"].strip
            info["Description"] = info["Description"].strip
            
            if( !info["Dependencies"] )
                info["Dependencies"] = []
            end
            
            info["Author"]    = info["Author"].strip
            info["Version"]   = info["Version"].strip 
            info["Path"]      = path['path'].strip
            
            i+=1
            
            mod_info << info
        }
        
        # clean the registry inloading all modules
        ModuleRegistry.clean( )
        
        return mod_info
    
    end

    private
    
    #
    # Takes care of module execution and threading
    #
    def run_mods( page_data, structure )

        mod_queue = Queue.new
        
        threads = ( 1..@opts[:threads] ).map {
            |i|
            Thread.new( mod_queue ) {
                |q|
                until( q == ( curr_mod = q.deq ) )
                    print_debug( )
                    print_debug( 'Thread-' + i.to_s + " " + curr_mod.inspect )
                    print_debug( )
                    
                    if $_interrupted == true
                        raise( 'Site audit was interrupted, exiting...' )
                    end
                    
                    print_status( curr_mod.to_s )
                    
                    mod_new = curr_mod.new( page_data, structure )
                    
                    mod_new.prepare   if curr_mod.method_defined?( 'prepare' )
                    mod_new.run
                    mod_new.clean_up  if curr_mod.method_defined?( 'clean_up' )
                end
            }
        }
        
        # enque the loaded mods
        for mod in ls_loaded
            mod_queue.enq mod
        end
        
        # send terminators down the queue
        threads.size.times { mod_queue.enq mod_queue }
        
        # wait for threads to finish
        threads.each { |t| t.join }
            
    end
    
    #
    # Takes care of some options that need slight processing
    #
    def parse_opts(  )

        @opts.each do |opt, arg|

            case opt.to_s

                when 'arachni_verbose'
                    verbose!

                when 'debug'
                    debug!

                when 'only_positives'
                    only_positives!

                when 'cookie_jar'
                    @opts[:cookies] =
                        HTTP.parse_cookiejar( @opts[:cookie_jar] )

#                when 'delay'
#                    @opts[:delay] = Float.new( @opts[:delay] ) 

            end
        end

    end

    #
    # Validates options
    #
    # If something is out of order an exception will be raised.
    #
    def validate_opts

        # TODO: remove global vars
        if !@opts[:user_agent]
            @opts[:user_agent] = $runtime_args[:user_agent] =
                'Arachni/' + VERSION
        end
        
        if !@opts[:audit_links] &&
            !@opts[:audit_forms] &&
            !@opts[:audit_cookies]
            raise( Arachni::Exceptions::NoAuditOpts,
                "No audit options were specified." )
        end

        #
        # Ensure that the user selected some modules
        #
        if !@opts[:mods]
            raise( Arachni::Exceptions::NoMods, "No modules were specified." )
        end

        # Check for missing url
        if @opts[:url] == nil
            raise( Arachni::Exceptions::NoURL, "Missing url argument." )
        end

        #
        # Try and parse URL.
        # If it fails inform the user of that fact and
        # give him some approriate examples.
        #
        begin
            require 'uri'
            @opts[:url] = URI.parse( URI.encode( @opts[:url] ) )
        rescue
            raise( Arachni::Exceptions::InvalidURL, "Invalid URL argument." )
        end

#        #
#        # If proxy type is socks include socksify
#        # and let it proxy all tcp connections for us.
#        #
#        # Then nil out the proxy opts or else they're going to be
#        # passed as an http proxy to Anemone::HTTP.refresh_connection()
#        #
#        if @opts[:proxy_type] == 'socks'
#            require 'socksify'
#
#            TCPSocket.socks_server = @opts[:proxy_addr]
#            TCPSocket.socks_port = @opts[:proxy_port]
#
#            @opts[:proxy_addr] = nil
#            @opts[:proxy_port] = nil
#        end

        #
        # If proxy type is socks include socksify
        # and let it proxy all tcp connections for us.
        #
        # Then nil out the proxy opts or else they're going to be
        # passed as an http proxy to Anemone::HTTP.refresh_connection()
        #
        if !@opts[:threads]
            @opts[:threads] = 3
        end
        
        # make sure the provided cookie-jar file exists
        if @opts[:cookie_jar] && !File.exist?( @opts[:cookie_jar] )
            raise( Arachni::Exceptions::NoCookieJar,
                'Cookie-jar \'' + @opts[:cookie_jar] +
                        '\' doesn\'t exist.' )
        end
        
    end

  
end

end
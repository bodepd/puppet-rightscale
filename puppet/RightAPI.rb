#!/usr/bin/ruby

require 'RightAPI'
require 'crack'

module Puppet 
  class RightAPI

    # creates a logged in API object.
    def initialize(username, password, account, version='1.0', newsession=false) 
      @username=username
      @password=password
      @account=account
      @api = ::RightAPI.new
      @base_url="#{@api.api_url}/#{@account}"
      @api.login(:username => @username, :password => @password, :account => @account) 
    end

    #
    # check an item to see if it matches all params
    #
    def check_params(item, params)
      if params.empty?
        true
      else
        bools=params.map do |k,v| 
#puts "|#{item[k.to_s]}=?#{v}|"
          item[k.to_s].nil? ? false: item[k.to_s].downcase == v.downcase
        end
        bools.inject{|a,b| a && b}
      end
    end

    # returns a single object from rightscale that matches the query.
    #   if multiple things match, it returns nil
    #     - type - type of thing that we are retrieving
    #     - params - list of params used for query unique objects
    #          key - key for server that should match value.
    # this returns a single object if the query returns something unique
    #   otherwise it returns nil
    def get_obj(type, params={}, size=1) 
      xml = @api.send(type)
      types = Crack::XML.parse(xml)[type].select do |item|
        check_params(item,params)
      end
#puts item.keys
    # return the unique object
      if size != -1
        if types.size == size
          types.first
        else
          # this is kind of strange, I return nil if there is more than one match
#puts 'not one'
#puts types
          nil
        end
      else
        types
      end
    end
    # get all settings ojects for all servers
    # returns a hash{:settings, :server}
    # NOTE: PDB this WILL NOT SCALE and is crazy slow, there must be a better way
    def get_server_settings(params={})
      # return data to be collected
      data = {}
      # get all servers
      servers=get_obj('servers', {}, -1)
      server=servers.each do |server|
        server_id=server['href'].match(/\d+$/).to_s
        #puts server_id
        settings_xml = @api.send("servers/#{server_id}/settings")
#puts settings_xml
        cracked_settings=Crack::XML.parse(settings_xml)['settings']
        if check_params(cracked_settings, params)
          data[server_id]={:settings => cracked_settings, :server => server}
        end
      end
      if data.size == 0
        puts 'no matches'
     elsif data.size > 1
        puts "server has more than one settings match #{data.size}"
      end 
      data
    end
  # runs a right script remotely
  #   deployment - deployment where servers exists.
  #   server - server
  #   right_script - name of script
  #   params - hash of input params that right_script needs
    def run_script(deployment_name, server_name, right_script, inputs={})
      deployment=get_obj('deployments', {:nickname => deployment_name})
      if deployment.nil?
        raise Exception, "could not retrieve deployment: #{deployment_name}"
      end
      dep_href=deployment['href']
      server=get_obj('servers', 
        {:nickname => server_name, :deployment_href => dep_href}
      )
      if server.nil?
        raise Exception, "could not retrieve server: #{server_name} deployment: #{deployment_name}"
      end
      server_id=server['href'].match(/\d+$/)
      script=get_obj('right_scripts', {:name => right_script})
      if script.nil?
        raise Exception, "no rightscript with name: #{right_script} for server: #{server_name} deployment: #{deployment_name}"
      end
      script_href=script['href']
      #puts "#{server_id}\n#{dep_href}\n#{script_href}"
      @api.send("servers/#{server_id}/run_script", 'post', 
        {:right_script => script_href}.merge(inputs)
      )
    end

    # given some parameters, we will retrieve a server
    # (via its settings), then retrieve the tags for that server's template.
    def get_tags(params={})
      servers=get_server_settings(params)
      if servers.size > 1
        raise Exception, "parameters #{params} did not return unique server"
      elsif servers.size == 0
        raise Exception, "parameters #{params} did not return any servers"
      end
      #puts servers.to_yaml
      tags={}
      server=servers.values.first[:server]
      template_id=server['server_template_href'].match(/\d+$/).to_s
        #puts "tags/search?resource_href=#{template_id}"
      template_url="#{@base_url}/server_templates/#{template_id}"
      tag_url="tags/search?resource_href=#{template_url}"
      #puts tag_url
      tags_xml=@api.send(tag_url)
      #puts tags_xml
      Crack::XML.parse(tags_xml)['tags']
    end


    # accepts a hash of options
    # we will query server settings for all machines that match those options.
    # if we find a single server, we will parse its tags to determine classes and params for a node
    def classify_puppet(opts)
      enc_yaml={:classes => [], :parameters => {}}
      tags=get_tags(opts)
      #puts tags.class
      tags.each do |tag|
        #puts tag.to_yaml
        (name, value)=tag['name'].split('=')
        #nputs name
        if name == 'puppet:class'
          enc_yaml[:classes].push(value)
        elsif name =~ (/puppet:parameter_(\w+)/)
          # params need to be strings, not symbols :(
          enc_yaml[:parameters][$1.to_s]=value
        else
        #
        end
      end
      enc_yaml
    end
  end
end

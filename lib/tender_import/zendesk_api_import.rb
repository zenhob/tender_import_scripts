require 'yajl'
require 'faraday'
require 'trollop'
require 'fileutils'
require 'logger'

# Produce a Tender import archive from a ZenDesk site using the ZenDesk API.
class TenderImport::ZendeskApiImport
  class Error < StandardError; end
  #class ResponseJSON < Faraday::Response::Middleware
  #  def parse(body)
  #    Yajl::Parser.parse(body)
  #  end
  #end

  module Log # {{{
    attr_reader :logger
    def log string
      logger.info "#{to_s}: #{string}"
    end

    def debug string
      logger.debug "#{to_s}: #{string}"
    end
  end # }}}

  class Client # {{{
    include Log
    attr_reader :opts, :conn, :subdomain

    # If no options are provided they will be obtained from the command-line.
    #
    # The options are subdomain, email and password.
    #
    # There is also an optional logger option, for use with Ruby/Rails
    def initialize(options = nil)
      @opts = options || command_line_options
      @subdomain = opts[:subdomain]
      @logger = opts[:logger] || Logger.new(STDOUT).tap {|l| l.level = Logger::INFO}
      @conn = Faraday::Connection.new("http://#{subdomain}.zendesk.com") do |b|
        b.adapter :net_http
        #b.use ResponseJSON
        b.response :yajl
      end
      conn.basic_auth(opts[:email], opts[:password])
    end

    def to_s
      "#{self.class.name} (#{subdomain})"
    end

    # API helpers # {{{
    def user user_id
      fetch_resource("users/#{user_id}.json")
    end

    def users
      fetch_paginated_resources("users.json?page=%d")
    end

    def forums
      fetch_resource("forums.json")
    end

    def entries forum_id
      fetch_paginated_resources("forums/#{forum_id}/entries.json?page=%d")
    end

    def posts entry_id
      fetch_paginated_resources("entries/#{entry_id}/posts.json?page=%d", 'posts')
    end

    def open_tickets
      fetch_paginated_resources("search.json?query=type:ticket+status:open+status:pending+status:new&page=%d")
    end
    # }}}
    
    protected # {{{

    # Fetch every page of a given resource. Must provide a sprintf format string
    # with a single integer for the page specification.
    #
    # Example: "users.json?page=%d"
    #
    # In some cases the desired data is not in the top level of the payload. In
    # that case specify resource_key to pull the data from that key.
    def fetch_resource resource_url, resource_key = nil
      debug "fetching #{resource_url}"
      loop do
        response = conn.get(resource_url)
        if response.success? && !response.body.kind_of?(String)
          return resource_key ? response.body[resource_key] : response.body
        elsif response.status == 503
          log "got a 503 (API throttle), waiting 30 seconds..."
          sleep 30
        else
          raise Error, "failed to get resource #{resource_format}: #{response.inspect}"
        end
      end
    end

    # Fetch every page of a given resource. Must provide a sprintf format string
    # with a single integer for the page specification.
    #
    # Example: "users.json?page=%d"
    #
    # In some cases the desired data is not in the top level of the payload. In
    # that case specify resource_key to pull the data from that key.
    def fetch_paginated_resources resource_format, resource_key = nil
      resources = []
      page = 1
      loop do
        resource = fetch_resource(resource_format % page, resource_key)
        break if resource.empty?
        page += 1
        resources += resource
      end
      resources
    end

    def command_line_options
      options = Trollop::options do
        banner <<-EOM
      Usage:
        #{$0} -e <email> -p <password> -s <subdomain>

      Prerequisites:
        # Ruby gems (should already be installed)
        gem install faraday
        gem install trollop
        gem install yajl-ruby

        # Python tools (must be in your PATH)
        html2text.py: http://www.aaronsw.com/2002/html2text/

      Options:
        EOM
        opt :email,       "user email address", :type => String
        opt :password,    "user password",      :type => String
        opt :subdomain,   "subdomain",          :type => String
      end

      [:email, :password, :subdomain ].each do |option|
        Trollop::die option, "is required" if options[option].nil?
      end
      return options
    end
    # }}}

  end # }}}

  class Exporter # {{{
    attr_reader :logger, :client
    include Log
    include FileUtils

    def initialize client
      @client = client
      @author_email = {}
      @logger = client.logger
      @archive = TenderImport::Archive.new(client.subdomain)
      if `which html2text.py`.empty?
        raise Error, 'missing prerequisite: html2text.py is not in your PATH'
      end
    end

    def to_s
      "#{self.class.name} (#{client.subdomain})"
    end

    def stats
      @archive.stats
    end

    def report
      @archive.report
    end

    def export_users # {{{
      log 'exporting users'
      client.users.each do |user|
        @author_email[user['id'].to_s] = user['email']
        log "exporting user #{user['email']}"
        @archive.add_user \
          :name => user['name'],
          :email => user['email'],
          :created_at => user['created_at'],
          :updated_at => user['updated_at'],
          :state => (user['roles'].to_i == 0 ? 'user' : 'support')
      end
    end # }}}

    def export_categories # {{{
      log 'exporting categories'
      client.forums.each do |forum|
        log "exporting category #{forum['name']}"
        category = @archive.add_category \
            :name => forum['name'],
            :summary => forum['description']
        export_discussions(forum['id'], category)
      end
    end # }}}

    def export_tickets # {{{
      log "exporting open tickets"
      tickets = client.open_tickets
      if tickets.size > 0
        # create category for tickets
        log "creating ticket category"
        category = @archive.add_category \
          :name => 'Tickets',
          :summary => 'Imported from ZenDesk.'
        # export tickets into new category
        tickets.each do |ticket|
          comments = ticket['comments'].map do |post|
            {
              :body => post['value'],
              :author_email => author_email(post['author_id']),
              :created_at => post['created_at'],
              :updated_at => post['updated_at'],
            }
          end
          log "exporting ticket #{ticket['nice_id']}"
          @archive.add_discussion category, 
            :title        => ticket['subject'],
            :state        => ticket['is_locked'] ? 'resolved' : 'open',
            :private      => !ticket['is_public'],
            :author_email => author_email(ticket['submitter_id']),
            :created_at   => ticket['created_at'],
            :updated_at   => ticket['updated_at'],
            :comments     => comments
        end
      end
    end # }}}

    def export_discussions forum_id, category # {{{
      client.entries(forum_id).each do |entry|
        comments = client.posts(entry['id']).map do |post|
          dump_body post, post['body']
          {
            :body => load_body(entry),
            :author_email => author_email(post['user_id']),
            :created_at => post['created_at'],
            :updated_at => post['updated_at'],
          }
        end
        dump_body entry, entry['body']
        log "exporting discussion #{entry['title']}"
        @archive.add_discussion category,
          :title    => entry['title'],
          :author_email => author_email(entry['submitter_id']),
          :comments => [{
            :body => load_body(entry),
            :author_email => author_email(entry['submitter_id']),
            :created_at => entry['created_at'],
            :updated_at => entry['updated_at'],
          }] + comments
        rm "tmp/#{entry['id']}_body.html"
      end
    end # }}}
  
    def create_archive # {{{
      export_file = @archive.write_archive
      log "created #{export_file}"
      return export_file
    end # }}}

    protected

    def author_email user_id
      # the cache should be populated during export_users but we'll attempt
      # to fetch unrecognized ids just in case
      @author_email[user_id.to_s] ||= (client.user(user_id)['email'] rescue nil)
    end

    def dump_body entry, body
      File.open(File.join("tmp", "#{entry['id']}_body.html"), "w") do |file|
        file.write(body)
      end
    end

    def load_body entry
      `html2text.py /$PWD/tmp/#{entry['id']}_body.html`
    end

  end # }}}

  # Produce a complete import archive either from API or command line options.
  def self.run options=nil
    begin
      client = Client.new options
      exporter = Exporter.new client
      exporter.export_users
      exporter.export_categories
      exporter.export_tickets
      exporter.create_archive
    rescue Error => e
      puts "FAILED WITH AN ERROR"
      puts e.to_s
      exit 1
    ensure
      if exporter
        puts "RESULTS"
        puts exporter.stats.inspect
        puts exporter.report.join("\n")
      end
    end
  end

end

# vi:foldmethod=marker

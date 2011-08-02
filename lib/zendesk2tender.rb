require 'yajl'
require 'faraday'
require 'trollop'
require 'fileutils'
require 'logger'

# Produce a Tender import archive from a ZenDesk site using the ZenDesk API.
class ZenDesk2Tender
  class Error < StandardError; end
  class ResponseJSON < Faraday::Response::Middleware
    def parse(body)
      Yajl::Parser.parse(body)
    end
  end
 
  include FileUtils
  attr_reader :opts, :conn, :export_dir, :logger

  # If no options are provided they will be obtained from the command-line.
  #
  # The options are subdomain, email and password.
  #
  # There is also an optional logger option, for use with Ruby/Rails
  def initialize(options = nil) # {{{
    @opts = options || command_line_options
    @author_email = {}
    @export_dir = ".#{opts[:subdomain]}-export-#{$$}"
    if `which html2text.py`.empty?
      raise Error, 'missing prerequisite: html2text.py is not in your PATH'
    end

    @logger = opts[:logger] || Logger.new(STDOUT).tap {|l| l.level = Logger::INFO}
    @conn = Faraday::Connection.new("http://#{opts[:subdomain]}.zendesk.com") do |b|
      b.adapter :net_http
      b.use ResponseJSON
    end
    conn.basic_auth(opts[:email], opts[:password])
  end # }}}

  #
  # ZENDESK
  #
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

  #
  # EXPORT
  #
  def export_users # {{{
    log 'exporting users'
    dir_name = File.join(export_dir,'users')
    mkdir_p dir_name
    users.each do |user|
      File.open(File.join(dir_name, "#{user['email'].gsub(/\W+/,'_')}.json"), "w") do |file|
        @author_email[user['id'].to_s] = user['email']
        log "exporting user #{user['email']}"
        file.puts(Yajl::Encoder.encode(
          :name => user['name'],
          :email => user['email'],
          :created_at => user['created_at'],
          :updated_at => user['updated_at'],
          :state => (user['roles'].to_i == 0 ? 'user' : 'support')
        ))
      end
    end
  end # }}}

  def export_categories # {{{
    log 'exporting categories'
    dir_name = File.join(export_dir,'categories')
    mkdir_p dir_name
    forums.each do |forum|
      File.open(File.join(dir_name, "#{forum['id']}.json"), "w") do |file|
        log "exporting category #{forum['name']}"
        file.puts(Yajl::Encoder.encode(
          :name => forum['name'],
          :summary => forum['description']
        ))
      end
      export_discussions(forum['id'])
    end
  end # }}}

  def export_tickets # {{{
    log "exporting open tickets"
    tickets = open_tickets
    if tickets.size > 0
      # create category for tickets
      dir_name = File.join(export_dir,'categories')
      mkdir_p "#{dir_name}"
      File.open(File.join(dir_name, "tickets.json"), "w") do |file|
        log "creating ticket category"
        file.puts(Yajl::Encoder.encode(
          :name => 'Tickets',
          :summary => 'Imported from ZenDesk.'
        ))
      end
      # export tickets into new category
      dir_name = File.join(export_dir,'categories', 'tickets')
      mkdir_p dir_name
      mkdir_p 'tmp'
      tickets.each do |ticket|
        File.open(File.join(dir_name, "#{ticket['nice_id']}.json"), "w") do |file|
          comments = ticket['comments'].map do |post|
            {
              :body => post['value'],
              :author_email => author_email(post['author_id']),
              :created_at => post['created_at'],
              :updated_at => post['updated_at'],
            }
          end
          log "exporting ticket #{ticket['nice_id']}"
          file.puts(Yajl::Encoder.encode(
            :title        => ticket['subject'],
            :author_email => author_email(ticket['submitter_id']),
            :created_at   => ticket['created_at'],
            :updated_at   => ticket['updated_at'],
            :comments     => comments
          ))
        end
      end
    end
  end # }}}

  def export_discussions forum_id # {{{
    dir_name = File.join(export_dir,'categories', forum_id.to_s)
    mkdir_p dir_name
    mkdir_p 'tmp'
    entries(forum_id).each do |entry|
      File.open(File.join(dir_name, "#{entry['id']}.json"), "w") do |file|
        comments = posts(entry['id']).map do |post|
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
        file.puts(Yajl::Encoder.encode(
          :title    => entry['title'],
          :comments => [{
            :body => load_body(entry),
            :author_email => author_email(entry['submitter_id']),
            :created_at => entry['created_at'],
            :updated_at => entry['updated_at'],
          }] + comments
        ))
        rm "tmp/#{entry['id']}_body.html"
      end
    end
  end # }}}

  def create_archive # {{{
    export_file = "export_#{opts[:subdomain]}.tgz"
    system "tar -zcf #{export_file} -C #{export_dir} ."
    system "rm -rf #{export_dir}"
    log "created #{export_file}"
  end # }}}

  # Produce a complete import archive either from API or command line options.
  def self.run options=nil
    begin
      exporter = new options
      exporter.export_users
      exporter.export_categories
      exporter.export_tickets
      exporter.create_archive
    rescue Error => e
      puts e.to_s
      exit 1
    end
  end

  protected # internal methods {{{

  def command_line_options
    options = Trollop::options do
      banner <<-EOM
    Usage:
      #{$0} -e <email> -p <password> -s <subdomain>

    Prerequisites:
      # Ruby gems
      gem install faraday -v "~>0.4.5"
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

  def author_email user_id
    # the cache should be populated during export_users but we'll attempt
    # to fetch unrecognized ids just in case
    @author_email[user_id.to_s] ||= (user(user_id)['email'] rescue nil)
  end

  def dump_body entry, body
    File.open(File.join("tmp", "#{entry['id']}_body.html"), "w") do |file|
      file.write(body)
    end
  end

  def load_body entry
    `html2text.py /$PWD/tmp/#{entry['id']}_body.html`
  end

  def log string
    logger.info "#{self.class.name} (#{opts[:subdomain]}): #{string}"
  end

  def debug string
    logger.debug "#{self.class.name} (#{opts[:subdomain]}): #{string}"
  end

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
      if response.success?
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
   # }}}

end

# vi:foldmethod=marker

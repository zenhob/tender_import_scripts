#
# Provides a Ruby API for constructing Tender import archives.
#
# https://help.tenderapp.com/faqs/setup-installation/importing
#
# ## Example
#
#     # Currently requires a site name.
#     archive = TenderImport::Archive.new('tacotown')
#
#     # Can add users, categories and discussions to the archive.
#     archive.add_user :email => 'frank@tacotown.com', :state => 'support'
#     archive.add_user :email => 'bob@bobfoo.com'
#
#     # When you add a category you'll get a handle needed to add discusions.
#     category = archive.add_category :name => 'Tacos'
#
#     # Discussions must have at least one comment.
#     archive.add_discussion category, :title => 'your tacos',
#       :author_email => 'bob@bobfoo.com',
#       :comments => [{
#         :author_email => 'bob@bobfoo.com',
#         :body => 'They are not so good.'
#       }, {
#         :author_email => 'frank@tacotown.com',
#         :body => 'You have terrible taste in tacos. Good day, sir.'
#       }]
#
#     # To add knowledge base you'll need sections
#     section = archive.add_section :name => 'Basic Help'
#     
#     archive.add_kb section, :title => 'How to get help',
#       :body => 'This is my awesome knowledge base'
#
#     # By default, files are written as you add them, so this will just
#     # assemble a gzipped tar archive from those files.
#     filename = archive.write_archive
#     puts "your import file is #{filename}"
#
#     # If any errors are reported, some records were not included in the archive.
#     if !archive.report.empty?
#       puts "Problems reported: ", *archive.report
#     end
#
require 'yajl'
require 'fileutils'
class TenderImport::Archive
  class Error < StandardError; end
  include FileUtils
  attr_reader :site, :report, :stats, :buffer

  # Options:
  #
  # buffer:: When true, don't flush to disk until the end. Defaults to false.
  #
  def initialize site_name, options = {}
    @site = site_name
    @export_dir = ".#{site_name}-export-#{$$}"
    @report = []
    @import = {}
    @stats = {}
    @buffer = options.key?(:buffer) ? !!options[:buffer] : false
    @category_counter = Hash.new(0)
    @section_counter = Hash.new(0)
  end

  # Returns the params on success, nil on failure
  def add_user params
    validate_and_store :user, {:state => 'user'}.merge(params)
  end
  
  # Returns a handle needed for adding discussions
  def add_category params
    cat = validate_and_store :category, params
    cat ? category_key(cat) : nil
  end
  
  def add_section params
    section = validate_and_store :section, params
    section ? section_key(section) : nil
  end
  
  def add_discussion category_key, params
    raise Error, "add_discussion: missing category key" if category_key.nil?
    validate_and_store :discussion, params, :key => category_key
  end
  
  def add_kb section_key, params
    raise Error, "add_kb: missing section key" if section_key.nil?
    validate_and_store :kb, params, :key => section_key
  end

  def category_key cat
    "category:#{category_id cat}".downcase
  end

  def category_id cat
    cat[:name].gsub(/\W+/,'_').downcase
  end
  
  def section_key section
    "section:#{section_id section}".downcase
  end
  
  def section_id section
    section[:title].gsub(/\W+/,'_').downcase
  end

  def categories
    @import[:category]
  end
  
  def sections
    @import[:section]
  end

  def discussions category_key
    raise Error, "discussions: missing category key" if category_key.nil?
    @import[category_key] || []
  end
  
  def kbs section_key
    raise Error, "kbs: missing section key" if section_key.nil?
    @import[section_key] || []
  end
  
  def users
    @import[:user]
  end

  def write_archive
    write_users if users
    write_categories_and_discussions if categories
    write_sections_and_kbs if sections
    export_file = "export_#{site}.tgz"
    system "tar -zcf #{export_file} -C #{export_dir} ."
    system "rm -rf #{export_dir}"
    return export_file
  end

  def write_user user
    return unless user
    mkdir_p export_dir('users')
    File.open(File.join(export_dir('users'), "#{user[:email].gsub(/\W+/,'_')}.json"), "w") do |file|
      file.puts Yajl::Encoder.encode(user)
    end
  end

  def write_users
    users.each do |u|
      write_user u
    end
  end

  def write_category c
    mkdir_p export_dir('categories')
    File.open(File.join(export_dir('categories'), "#{category_id(c)}.json"), "w") do |file|
      file.puts Yajl::Encoder.encode(c)
    end
  end
  
  def write_section s
    mkdir_p export_dir('sections')
    File.open(File.join(export_dir('sections'), "#{section_id(s)}.json"), "w") do |file|
      file.puts Yajl::Encoder.encode(s)
    end
  end

  def write_categories_and_discussions
    categories.each do |c|
      write_category c
      write_discussions c
    end
  end
  
  def write_sections_and_kbs
    sections.each do |s|
      write_section s
      write_kbs s
    end
  end

  def write_discussion category_id, discussion
    @category_counter[category_id] += 1
    dir = File.join(export_dir('categories'), category_id)
    mkdir_p dir
    File.open(File.join(dir, "#{@category_counter[category_id]}.json"), "w") do |file|
      file.puts Yajl::Encoder.encode(discussion)
    end
  end
  
  def write_kb section_id, kb
    @section_counter[section_id] += 1
    dir = File.join(export_dir('sections'), section_id)
    mkdir_p dir
    File.open(File.join(dir, "#{@section_counter[section_id]}.json"), "w") do |file|
      file.puts Yajl::Encoder.encode(kb)
    end
  end

  def write_discussions category
    discussions(category_key(category)).each do |d|
      write_discussion category_id(category), d
    end
  end
  
  def write_kbs section
    kbs(section_key(section)).each do |k|
      write_kb section_id(s), k
    end
  end

  protected

  def validate_and_store *args
    type, params, options = args
    options ||= {}
    key = options[:key] || type
    @import[key] ||= []
    if valid? type, params
      if buffer
        # save in memory and flush to disk at the end
        @import[key] << params
      else
        # write immediately instead of storing in memory
        write *args
      end
      @stats[key] ||= 0
      @stats[key] += 1
      params
    else
      @stats["invalid:#{key}"] ||= 0
      @stats["invalid:#{key}"] += 1
      nil
    end
  end

  def write type, params, options = {}
    case type
    when :discussion
      # ughh
      write_discussion options[:key].split(':',2)[1], params
    when :category
      write_category params
    when :user
      write_user params
    when :section
      write_section params
    when :kb
      write_kb options[:key].split(':',2)[1], params
    end
  end

  def valid? type, params
    problems = []
    # XXX this is not really enough validation, also it's ugly as fuck
    if type == :user && (params[:email].nil? || params[:email].empty?)
      problems << "Missing email in user data: #{params.inspect}."
    end
    if type == :user && !%w[user support].include?(params[:state])
      problems << "Invalid state in user data: #{params.inspect}."
    end
    if type == :category && (params[:name].nil? || params[:name].empty?)
      problems << "Missing name in category data: #{params.inspect}."
    end
    if type == :discussion && (params[:author_email].nil? || params[:author_email].empty?)
      problems << "Missing author_email in discussion data: #{params.inspect}."
    end
    if type == :discussion && (params[:comments].nil? || params[:comments].any? {|c| c[:author_email].nil? || c[:author_email].empty?})
      problems << "Missing comments and authors in discussion data: #{params.inspect}."
    end
    if type == :kb && (params[:title].nil? || params[:title].empty? || params[:body].nil? || params[:body].empty?)
      problems << "Missing title or body in kb: #{params.inspect}"
    end
    if problems.empty?
      true
    else
      @report += problems
      false
    end
  end

  def export_dir subdir=nil
    subdir.nil? ? @export_dir : File.join(@export_dir, subdir.to_s)
  end

end

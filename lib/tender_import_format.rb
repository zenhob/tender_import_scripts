#
# Provides a Ruby API for constructing Tender import archives.
#
# https://help.tenderapp.com/faqs/setup-installation/importing
#
# ## Example
#
#     archive = TenderImportFormat.new('tacotown')
#     archive.add_user :email => 'frank@tacotown.com', :state => 'support'
#     archive.add_user :email => 'bob@bobfoo.com'
#     category = archive.add_category :name => 'Tacos'
#     archive.add_discussion category, :title => 'your tacos',
#       :author_email => 'bob@bobfoo.com',
#       :comments => [{
#         :author_email => 'bob@bobfoo.com',
#         :body => 'They are not so good.'
#       }, {
#         :author_email => 'frank@tacotown.com',
#         :body => 'You have terrible taste in tacos. Good day, sir.'
#       }]
#     filename = archive.write_archive
#     puts "your import file is #{filename}"
#     if !archive.report.empty?
#       puts "Problems reported: ", *archive.report
#     end
#
require 'yajl'
require 'fileutils'
class TenderImportFormat
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
  end

  # Returns the params on success, nil on failure
  def add_user params
    defaults = {:state => 'user'}
    validate_and_store :user, defaults.merge(params)
  end
  
  # Returns a handle needed for adding discussions
  def add_category params
    cat = validate_and_store :category, params
    cat ? category_key(cat) : nil
  end
  
  def add_discussion category_key, params
    raise Error, "add_discussion: missing category key" if category_key.nil?
    validate_and_store :discussion, params, :key => category_key
  end

  def category_key cat
    "category:#{category_id cat}"
  end

  def category_id cat
    cat[:name].gsub(/\W+/,'_')
  end

  def categories
    @import[:category]
  end

  def discussions category_key
    raise Error, "discussions: missing category key" if category_key.nil?
    @import[category_key] || []
  end
  
  def users
    @import[:user]
  end

  def write_archive
    write_users if users
    write_categories_and_discussions if categories
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

  def write_categories_and_discussions
    categories.each do |c|
      write_category c
      write_discussions c
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

  def write_discussions category
    discussions(category_key(category)).each do |d|
      write_discussion category_id(category), d
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
    end
  end

  def valid? type, params
    problems = []
    # XXX this is not really enough validation
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

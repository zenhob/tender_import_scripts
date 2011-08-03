#
# Provides a Ruby API for constructing Tender import archives.
#
# https://help.tenderapp.com/faqs/setup-installation/importing
#
require 'yajl'
require 'fileutils'
class TenderImportFormat
  class Error < StandardError; end

  include FileUtils
  attr_reader :site, :report
  def initialize site_name
    @site = site_name
    @export_dir = ".#{site_name}-export-#{$$}"
    @report = []
    @import = {}
  end

  def add_user params
    validate_and_store :user, params
  end
  
  # returns a handle needed for adding discussions
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

  def stats
    @import.inject({}) {|memo, (k, v)| memo[k] = v.size; memo}
  end

  def write_archive
    write_users
    write_categories
    export_file = "export_#{site}.tgz"
    system "tar -zcf #{export_file} -C #{export_dir} ."
    system "rm -rf #{export_dir}"
    return export_file
  end

  def write_users
    mkdir_p export_dir('users')
    users.each do |u|
      File.open(File.join(export_dir('users'), "#{u[:email].gsub(/\W+/,'_')}.json"), "w") do |file|
        file.puts Yajl::Encoder.encode(u)
      end
    end
  end

  def write_categories
    mkdir_p export_dir('categories')
    categories.each do |c|
      File.open(File.join(export_dir('categories'), "#{category_id(c)}.json"), "w") do |file|
        file.puts Yajl::Encoder.encode(c)
      end
      write_discussions(c)
    end
  end

  def write_discussions category
    dir = File.join(export_dir('categories'), category_id(category))
    mkdir_p dir
    counter = 0
    discussions(category_key(category)).each do |d|
      counter += 1
      File.open(File.join(dir, "#{counter}.json"), "w") do |file|
        file.puts Yajl::Encoder.encode(d)
      end
    end
  end

  protected

  def validate_and_store type, params, options = {}
    key = options[:key] || type
    @import[key] ||= []
    if valid? type, params
      @import[key] << params
      return params
    end
    nil
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

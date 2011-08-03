$LOAD_PATH.unshift 'lib'
require "tender_import/version"

Gem::Specification.new do |s|
  s.name              = "tender_import"
  s.version           = TenderImport::VERSION
  s.date              = Time.now.strftime('%Y-%m-%d')
  s.summary           = "Tools for producing Tender import archives."
  s.homepage          = "https://help.tenderapp.com/kb/setup-installation/importing"
  s.email             = "zack@zackhobson.com"
  s.authors           = [ "Zack Hobson" ]
  s.has_rdoc          = false
  s.add_dependency('faraday')
  s.add_dependency('trollop')
  s.add_dependency('yajl-ruby')

  s.files             = %w( README.md )
  s.files            += Dir.glob("lib/**/*")
  s.files            += Dir.glob("bin/**/*")

  s.executables       = %w( zendesk2tender )
  s.description       = <<-EOM
These are tools written in Ruby to support importing data into Tender.

For more information:

https://help.tenderapp.com/kb/setup-installation/importing
  EOM
end

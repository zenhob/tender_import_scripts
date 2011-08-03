# Tender Import Tools

This is a repository of code for producing [Tender import
archives](https://help.tenderapp.com/faqs/setup-installation/importing),
for Tender customers who wish to move their discussions from another service.

The methods used to produce an import archive will vary with the service
and the facilities they provide, such as data dumps or API access. These
scripts are being made available in the hopes that they'll be useful, but
it's up to you to review them before running them on your own computer or
against an existing service. We aren't responsible if your computer blows
up or you are banned from an existing service for TOS violations, or both.

That said, if you make useful or necessary modifications to a script, or
produce a script for importing from a new service, please
[open a Tender discussion](https://help.tenderapp.com/discussions/suggestions#new_topic_form)
or send a pull request to let us know.

## Installation

This toolset can be installed as a Ruby gem:

    $ gem install tender_import

## Command-line

The only command-line tool included is zendesk2tender:

    $ zendesk2tender --help

## API

There is also an API for building Tender import archives with Ruby.

See lib/tender_import/archive.rb for an example of API usage.


source "http://rubygems.org"

gemspec

group :test do
  gem "rake"
  gem "rspec"
  gem "ci_reporter"
  gem "dm-sqlite-adapter"
  gem 'vcap_common', :require => ['vcap/common', 'vcap/component'], :git => 'https://github.com/cloudfoundry/vcap-common.git', :ref => '658be8a8f6'
  gem 'vcap_logging', :require => ['vcap/logging'], :git => 'https://github.com/cloudfoundry/common.git', :ref => 'b96ec1192d'
  gem 'vcap_services_messages', :git => 'https://github.com/vchs/vcap-services-messages.git', :ref => 'ea67f4dfe2'
  gem 'warden-client', :require => ['warden/client'], :git => 'https://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
  gem 'warden-protocol', :require => ['warden/protocol'], :git => 'https://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
  gem 'simplecov'
  gem 'simplecov-rcov'
  gem 'debugger'
  gem 'webmock'
  gem 'rack-test'
  gem 'mock_redis'
end

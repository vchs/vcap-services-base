source "http://rubygems.org"

gemspec

gem "fog"

group :test do
  gem "rake"
  gem "rspec"
  gem "ci_reporter"
  gem "dm-sqlite-adapter"
  gem 'vcap_common', :require => ['vcap/common', 'vcap/component'], :git => 'git://github.com/cloudfoundry/vcap-common.git', :ref => '658be8a8f6'
  gem 'vcap_logging', :require => ['vcap/logging'], :git => 'git://github.com/cloudfoundry/common.git', :ref => 'b96ec1192d'
  gem 'warden-client', :require => ['warden/client'], :git => 'git://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
  gem 'warden-protocol', :require => ['warden/protocol'], :git => 'git://github.com/cloudfoundry/warden.git', :ref => 'fe6cb51'
  gem 'debugger'
  gem 'webmock'
  gem 'rack-test'
end

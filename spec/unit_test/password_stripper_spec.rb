require 'helper/spec_helper'
require 'base/password_stripper'

module VCAP::Services::Base
  describe PasswordStripper do
    include VCAP::Services::Base::PasswordStripper

    it 'should strip password' do
      old_hash = { password: 'a',
                   key2: [ { passwd: 'b' }, { key21: 'c'} ],
                   key3: [ [ { key31: [ password: 'd'] }, { 'pass' => 'e'} ] ],
                   key4: 'f'
                 }
      new_hash = strip_password(old_hash)
      new_hash.should == {
                   key2: [ {}, { key21: 'c' } ],
                   key3: [ [ { key31: [{}] }, {} ] ],
                   key4: 'f'
                 }
    end

  end
end

require "open3"

module VCAP::Services::Base::PasswordStripper
  PASSWORD_KEYS = %w(password pass passwd)
  def strip_password(obj)
    if obj.is_a? Array
      return obj.map { |item| strip_password(item) }
    elsif obj.is_a? (Hash)
      PASSWORD_KEYS.each do |key|
        obj.delete(key)
        obj.delete(key.to_sym)
      end
      new_hash = {}
      obj.each do |k, v|
        new_hash[k] = strip_password(v)
      end
      new_hash
    else
      obj
    end
  end
end

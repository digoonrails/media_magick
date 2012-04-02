require 'active_support/concern'
require 'carrierwave'
require 'media_magick/attachment_uploader'
require 'mongoid'
require 'carrierwave/validations/active_model'

module CarrierWave
  module Mongoid
    include CarrierWave::Mount
    ##
    # See +CarrierWave::Mount#mount_uploader+ for documentation
    #
    def mount_uploader(column, uploader=nil, options={}, &block)
      field options[:mount_on] || column

      super

      alias_method :read_uploader, :read_attribute
      alias_method :write_uploader, :write_attribute
      public :read_uploader
      public :write_uploader

      include CarrierWave::Validations::ActiveModel

      validates_integrity_of column if uploader_option(column.to_sym, :validate_integrity)
      validates_processing_of column if uploader_option(column.to_sym, :validate_processing)

      after_save :"store_#{column}!"
      before_save :"write_#{column}_identifier"
      after_destroy :"remove_#{column}!"
      before_update :"store_previous_model_for_#{column}"
      after_save :"remove_previously_stored_#{column}"

      class_eval <<-RUBY, __FILE__, __LINE__+1
def #{column}=(new_file)
column = _mounter(:#{column}).serialization_column
send(:"\#{column}_will_change!")
super
end

# Overrides Mongoid's default dirty behavior to instead work more like
# ActiveRecord's. Mongoid doesn't deem an attribute as changed unless
# the new value is different than the original. Given that CarrierWave
# caches files before save, it's necessary to know that there's a
# pending change even though the attribute value itself might not
# reflect that yet.
def #{column}_changed?
changed_attributes.has_key?("#{column}")
end

def find_previous_model_for_#{column}
if self.embedded?
ancestors = [[ self.metadata.key, self._parent ]].tap { |x| x.unshift([ x.first.last.metadata.key, x.first.last._parent ]) while x.first.last.embedded? }
first_parent = ancestors.first.last
reloaded_parent = first_parent.class.find(first_parent.to_key.first)
association = ancestors.inject(reloaded_parent) { |parent,(key,ancestor)| (parent.is_a?(Array) ? parent.find(ancestor.to_key.first) : parent).send(key) }
association.is_a?(Array) ? association.find(to_key.first) : association
else
self.class.find(to_key.first)
end
end
RUBY
    end
  end # Mongoid
end # CarrierWave

Mongoid::Document::ClassMethods.send(:include, CarrierWave::Mongoid)

module MediaMagick
  module Model
    extend ActiveSupport::Concern
    
    module ClassMethods
      def attachs_many(name, options = {}, &block)
        klass = Class.new do
          include Mongoid::Document
          extend CarrierWave::Mount

          embedded_in :attachmentable, polymorphic: true
          mount_uploader name.to_s.singularize, AttachmentUploader unless options[:custom_uploader]

          self.const_set "TYPE", options[:type] || :image
          self.const_set "ATTACHMENT", name.to_s.singularize
          
          class_eval(&block) if block_given?

          def method_missing(method, args = nil)
            return self.send(self.class::ATTACHMENT).file.filename if method == :filename
            self.send(self.class::ATTACHMENT).send(method)
          end
        end

        Object.const_set "#{self.name}#{name.capitalize}", klass

        embeds_many(name, :as => :attachmentable, class_name: "#{self}#{name.capitalize}")
      end
    end
  end
end

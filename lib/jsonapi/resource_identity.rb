# frozen_string_literal: true

module JSONAPI

  # ResourceIdentity describes a unique identity of a resource in the system.
  # This consists of a Resource class and an identifier that is unique within
  # that Resource class. ResourceIdentities are intended to be used as hash
  # keys to provide ordered mixing of resource types in result sets.
  #
  #
  # == Creating a ResourceIdentity
  #
  # rid = ResourceIdentity.new(PostResource, 12)
  #
  class ResourceIdentity
    attr_reader :resource_klass, :id

    def initialize(resource_klass, id)
      @resource_klass = resource_klass
      @id = id
    end

    def ==(other)
      # :nocov:
      eql?(other)
      # :nocov:
    end

    def eql?(other)
      other.is_a?(ResourceIdentity) &&
        model_class_match?(other) &&
        other.id == @id
    end

    def hash
      [_table_name, @id].hash
    end

    def <=>(other_identity)
      self.id <=> other_identity.id
    end

    # Creates a string representation of the identifier.
    def to_s
      # :nocov:
      "#{resource_klass}:#{id}"
      # :nocov:
    end

  private

    def model_class_match? other
      return other.resource_klass == resource_klass unless sti_model?
      other.resource_klass._table_name == _table_name
    end

    delegate :sti_model?, :_table_name, to: :resource_klass, private: true
  end
end

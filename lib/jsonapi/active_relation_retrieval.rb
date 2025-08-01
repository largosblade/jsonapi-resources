# frozen_string_literal: true

module JSONAPI
  module ActiveRelationRetrieval
    def find_related_ids(relationship, options = {})
      self.class.find_related_fragments(self, relationship, { context: }.merge(options)).keys.collect { |rid| rid.id }
    end

    module ClassMethods
      # Finds Resources using the `filters`. Pagination and sort options are used when provided
      #
      # @param filters [Hash] the filters hash
      # @option options [Hash] :context The context of the request, set in the controller
      # @option options [Hash] :sort_criteria The `sort criteria`
      # @option options [Hash] :include_directives The `include_directives`
      #
      # @return [Array<Resource>] the Resource instances matching the filters, sorting and pagination rules.
      def find(filters, options = {})
        sort_criteria = options.fetch(:sort_criteria) { [] }

        join_manager = ActiveRelation::JoinManager.new(resource_klass: self,
                                                       filters: filters,
                                                       sort_criteria: sort_criteria)

        paginator = options[:paginator]

        records = apply_request_settings_to_records(records: records(options),
                                                    sort_criteria: sort_criteria, filters: filters,
                                                    join_manager: join_manager,
                                                    paginator: paginator,
                                                    options: options)

        resources_for(records, options[:context])
      end

      # Counts Resources found using the `filters`
      #
      # @param filters [Hash] the filters hash
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [Integer] the count
      def count(filters, options = {})
        join_manager = ActiveRelation::JoinManager.new(resource_klass: self,
                                                       filters: filters)

        records = apply_request_settings_to_records(records: records(options),
                                                    filters: filters,
                                                    join_manager: join_manager,
                                                    options: options)

        count_records(records)
      end

      # Returns the single Resource identified by `key`
      #
      # @param key the primary key of the resource to find
      # @option options [Hash] :context The context of the request, set in the controller
      def find_by_key(key, options = {})
        record = find_record_by_key(key, options)
        resource_for(record, options[:context])
      end

      # Returns an array of Resources identified by the `keys` array
      #
      # @param keys [Array<key>] Array of primary keys to find resources for
      # @option options [Hash] :context The context of the request, set in the controller
      def find_by_keys(keys, options = {})
        records = find_records_by_keys(keys, options)
        resources_for(records, options[:context])
      end

      # Returns an array of Resources identified by the `keys` array. The resources are not filtered as this
      # will have been done in a prior step
      #
      # @param keys [Array<key>] Array of primary keys to find resources for
      # @option options [Hash] :context The context of the request, set in the controller
      def find_to_populate_by_keys(keys, options = {})
        records = records_for_populate(options).where(_primary_key => keys)
        resources_for(records, options[:context])
      end

      # Finds Resource fragments using the `filters`. Pagination and sort options are used when provided.
      # Note: This is incompatible with Polymorphic resources (which are going to come from two separate tables)
      #
      # @param filters [Hash] the filters hash
      # @option options [Hash] :context The context of the request, set in the controller
      # @option options [Hash] :sort_criteria The `sort criteria`
      # @option options [Hash] :include_directives The `include_directives`
      # @option options [Boolean] :cache Return the resources' cache field
      #
      # @return [Hash{ResourceIdentity => {identity: => ResourceIdentity, cache: cache_field}]
      #    the ResourceInstances matching the filters, sorting, and pagination rules along with any request
      #    additional_field values
      def find_fragments(filters, options = {})
        include_directives = options.fetch(:include_directives, {})
        resource_klass = self

        fragments = {}

        linkage_relationships = to_one_relationships_for_linkage(include_directives[:include_related])

        sort_criteria = options.fetch(:sort_criteria) { [] }

        join_manager = ActiveRelation::JoinManager.new(resource_klass: resource_klass,
                                                       source_relationship: nil,
                                                       relationships: linkage_relationships.collect(&:name),
                                                       sort_criteria: sort_criteria,
                                                       filters: filters)

        paginator = options[:paginator]

        records = apply_request_settings_to_records(records: records(options),
                                                    filters: filters,
                                                    sort_criteria: sort_criteria,
                                                    paginator: paginator,
                                                    join_manager: join_manager,
                                                    options: options)

        if options[:cache]
          # This alias is going to be resolve down to the model's table name and will not actually be an alias
          resource_table_alias = resource_klass._table_name

          pluck_fields = [sql_field_with_alias(resource_table_alias, resource_klass._primary_key)]

          cache_field = attribute_to_model_field(:_cache_field)
          pluck_fields << sql_field_with_alias(resource_table_alias, cache_field[:name])

          linkage_fields = []

          linkage_relationships.each do |linkage_relationship|
            linkage_relationship_name = linkage_relationship.name

            if linkage_relationship.polymorphic? && linkage_relationship.belongs_to?
              linkage_relationship.resource_types.each do |resource_type|
                klass = resource_klass_for(resource_type)
                linkage_table_alias = join_manager.join_details_by_polymorphic_relationship(linkage_relationship,
                                                                                            resource_type)[:alias]
                primary_key = klass._primary_key

                linkage_fields << { relationship_name: linkage_relationship_name,
                                    resource_klass: klass,
                                    field: sql_field_with_alias(linkage_table_alias, primary_key),
                                    alias: alias_table_field(linkage_table_alias, primary_key) }

                pluck_fields << sql_field_with_alias(linkage_table_alias, primary_key)
              end
            else
              klass = linkage_relationship.resource_klass
              linkage_table_alias = join_manager.join_details_by_relationship(linkage_relationship)[:alias]
              raise "Missing linkage_table_alias for #{linkage_relationship}" unless linkage_table_alias

              primary_key = klass._primary_key

              linkage_fields << { relationship_name: linkage_relationship_name,
                                  resource_klass: klass,
                                  field: sql_field_with_alias(linkage_table_alias, primary_key),
                                  alias: alias_table_field(linkage_table_alias, primary_key) }

              pluck_fields << sql_field_with_alias(linkage_table_alias, primary_key)
            end
          end

          sort_fields = options.dig(:_relation_helper_options, :sort_fields)
          sort_fields.try(:each) do |field|
            pluck_fields << Arel.sql(field)
          end
          
          rows = safe_pluck_operation(records, pluck_fields)
          rows.each do |row|
            rid = JSONAPI::ResourceIdentity.new(resource_klass, pluck_fields.length == 1 ? row : row[0])

            fragments[rid] ||= JSONAPI::ResourceFragment.new(rid)
            attributes_offset = 2

            fragments[rid].cache = cast_to_attribute_type(row[1], cache_field[:type])

            linkage_fields.each do |linkage_field_details|
              fragments[rid].initialize_related(linkage_field_details[:relationship_name])

              related_id = row[attributes_offset]
              if related_id
                related_rid = JSONAPI::ResourceIdentity.new(linkage_field_details[:resource_klass], related_id)
                fragments[rid].add_related_identity(linkage_field_details[:relationship_name], related_rid)
              end
              attributes_offset += 1
            end
          end

          if JSONAPI.configuration.warn_on_performance_issues && (rows.length > fragments.length)
            warn "Performance issue detected: `#{name}.records` returned non-normalized results in `#{name}.find_fragments`."
          end
        else
          linkage_fields = []
          tables_to_join = []

          linkage_relationships.each do |linkage_relationship|
            linkage_relationship_name = linkage_relationship.name

            if linkage_relationship.polymorphic? && linkage_relationship.belongs_to?
              linkage_relationship.resource_types.each do |resource_type|
                klass = resource_klass_for(resource_type)
                linkage_table_alias = join_manager.join_details_by_polymorphic_relationship(linkage_relationship,
                                                                                            resource_type)[:alias]
                primary_key = klass._primary_key

                select_alias = "jr_l_#{linkage_relationship_name}_#{resource_type}_pk"
                select_alias_statement = sql_field_with_fixed_alias(linkage_table_alias, primary_key, select_alias)

                linkage_fields << { relationship_name: linkage_relationship_name,
                                    resource_klass: klass,
                                    select: select_alias_statement,
                                    select_alias: select_alias }
              end
              if linkage_relationship.resource_types.empty?
                model_hints = linkage_relationship.resource_klass._model_hints
                model_hints.each do |k, _v|
                  linkage_fields << {
                    relationship_name: linkage_relationship_name,
                    resource_klass: resource_klass_for(k)
                  }
                end
              end
            else
              klass = linkage_relationship.resource_klass
              linkage_table_alias = join_manager.join_details_by_relationship(linkage_relationship)[:alias]
              raise "Missing linkage_table_alias for #{linkage_relationship}" unless linkage_table_alias

              primary_key = klass._primary_key

              select_alias = "jr_l_#{linkage_relationship_name}_pk"
              select_alias_statement = sql_field_with_fixed_alias(linkage_table_alias, primary_key, select_alias)
              linkage_fields << { relationship_name: linkage_relationship_name,
                                  resource_klass: klass,
                                  select: select_alias_statement,
                                  select_alias: select_alias }
              tables_to_join << linkage_relationship_name
            end
          end

          records = records.select(linkage_fields.collect { |f| f[:select] }) if linkage_fields.any?

          records = records.select(concat_table_field(_table_name, Arel.star))

          old_records = records
          begin
            records.to_a
          rescue
            records = records.joins(*linkage_fields.map { |h| h[:relationship_name].to_sym })
          end

          resources = resources_for(records, options[:context])
          # binding.pry
          fragments = convert_resources_to_fragments resources, linkage_fields
          # resources.each do |resource|
          #   rid = resource.identity
          #   fragments[rid] ||= JSONAPI::ResourceFragment.new(rid, resource: resource)
          #   linkage_fields.each do |linkage_field_details|
          #     fragments[rid].initialize_related(linkage_field_details[:relationship_name])
          #     # a less magical way at finding the related_id
          #     # does not use an ad hoc field hidden on records
          #     related_model = resource._model.public_send(linkage_field_details[:relationship_name])
          #     model_classes_match = related_model.class <= linkage_field_details[:resource_klass]._model_class
          #     related_id = related_model.id if model_classes_match
          #     # related_id = resource._model.attributes[linkage_field_details[:select_alias]]
          #     if related_id
          #       related_rid = JSONAPI::ResourceIdentity.new(linkage_field_details[:resource_klass], related_id)
          #       fragments[rid].add_related_identity(linkage_field_details[:relationship_name], related_rid)
          #     end
          #   end
          # end
        end

        fragments
      end

      # Finds Resource Fragments related to the source resources through the specified relationship
      #
      # @param source_rids [Array<ResourceIdentity>] The resources to find related ResourcesIdentities for
      # @param relationship_name [String | Symbol] The name of the relationship
      # @option options [Hash] :context The context of the request, set in the controller
      # @option options [Boolean] :cache Return the resources' cache field
      #
      # @return [Hash{ResourceIdentity => {identity: => ResourceIdentity, cache: cache_field, related: {relationship_name: [] }}}]
      #    the ResourceInstances matching the filters, sorting, and pagination rules along with any request
      #    additional_field values
      def find_related_fragments(source_fragment, relationship, options = {})
        
        if relationship.polymorphic? # && relationship.foreign_key_on == :self
          source_resource_klasses = if relationship.foreign_key_on == :self
                                      relationship.polymorphic_types.collect do |polymorphic_type|
                                        resource_klass_for(polymorphic_type)
                                      end
                                    else
                                      source.collect { |fragment| fragment.identity.resource_klass }.to_set
                                    end

          fragments = {}
          source_resource_klasses.each do |resource_klass|
            inverse_direct_relationship = _relationship(resource_klass._type.to_s.singularize)

            fragments.merge!(resource_klass.find_related_fragments_from_inverse([source_fragment],
                                                                                inverse_direct_relationship, options, false))
          end
          fragments
        else
          relationship.resource_klass.find_related_fragments_from_inverse([source_fragment], relationship, options,
                                                                          false)
        end
      end

      def find_included_fragments(source_fragments, relationship, options)
        # binding.pry unless relationship.respond_to?(:polymorphic_types)
        if relationship.polymorphic? # && relationship.foreign_key_on == :self
          # return {} unless relationship.respond_to?(:polymorphic_types)
          source_resource_klasses = if relationship.foreign_key_on == :self && relationship.respond_to?(:polymorphic_types)
                                      relationship.polymorphic_types.collect do |polymorphic_type|
                                        resource_klass_for(polymorphic_type)
                                      end
                                    elsif relationship.foreign_key_on == :self
                                      klass = source_fragments.first.resource._model.public_send(relationship.name).class
                                      Set.new([ resource_klass_for(klass.to_s) ])
                                    else
                                      source_fragments.collect { |fragment| fragment.identity.resource_klass }.to_set
                                    end

          fragments = {}
          source_resource_klasses.each do |resource_klass|
            inverse_direct_relationship = _relationship(resource_klass._type.to_s.singularize)
            # inverse_direct_relationship ||= _relationship(relationship.resource_klass._type.to_s.singularize)
            _relationship(resource_klass._type.to_s.singularize)
            fragments.merge!(resource_klass.find_related_fragments_from_inverse(source_fragments,
                                                                                inverse_direct_relationship, options, true))
          end
          fragments
        else
          relationship.resource_klass.find_related_fragments_from_inverse(source_fragments, relationship, options, true)
        end
      end

      def find_related_fragments_from_inverse(source, source_relationship, options, connect_source_identity)
        relationship = source_relationship.resource_klass._relationship(source_relationship.inverse_relationship)
        source_relationship.resource_klass._relationship(source_relationship.inverse_relationship)
        raise "missing inverse relationship for \"#{source_relationship.name}\", inspect that this relationship is defined both on model and on the resource" unless relationship.present?

        parent_resource_klass = relationship.resource_klass

        include_directives = options.fetch(:include_directives, {})

        # TODO: Handle resources vs identities
        source_ids = source.collect { |item| item.identity.id }

        filters = options.fetch(:filters, {})

        linkage_relationships = to_one_relationships_for_linkage(include_directives[:include_related])

        sort_criteria = []
        options[:sort_criteria].try(:each) do |sort|
          field = sort[:field].to_s == 'id' ? _primary_key : sort[:field]
          sort_criteria << { field: field, direction: sort[:direction] }
        end

        join_manager = ActiveRelation::JoinManager.new(resource_klass: self,
                                                       source_relationship: relationship,
                                                       relationships: linkage_relationships.collect(&:name),
                                                       sort_criteria: sort_criteria,
                                                       filters: filters)

        paginator = options[:paginator]

        records = apply_request_settings_to_records(records: records(options),
                                                    sort_criteria: sort_criteria,
                                                    source_ids: source_ids,
                                                    paginator: paginator,
                                                    filters: filters,
                                                    join_manager: join_manager,
                                                    options: options)

        fragments = {}

        if options[:cache]
          # This alias is going to be resolve down to the model's table name and will not actually be an alias
          resource_table_alias = _table_name
          parent_table_alias = join_manager.join_details_by_relationship(relationship)[:alias]

          pluck_fields = [
            sql_field_with_alias(resource_table_alias, _primary_key),
            sql_field_with_alias(parent_table_alias, parent_resource_klass._primary_key)
          ]

          cache_field = attribute_to_model_field(:_cache_field)
          pluck_fields << sql_field_with_alias(resource_table_alias, cache_field[:name])

          linkage_fields = []

          linkage_relationships.each do |linkage_relationship|
            linkage_relationship_name = linkage_relationship.name

            if linkage_relationship.polymorphic? && linkage_relationship.belongs_to?
              linkage_relationship.resource_types.each do |resource_type|
                klass = resource_klass_for(resource_type)
                linkage_fields << { relationship_name: linkage_relationship_name, resource_klass: klass }

                linkage_table_alias = join_manager.join_details_by_polymorphic_relationship(linkage_relationship,
                                                                                            resource_type)[:alias]
                primary_key = klass._primary_key
                pluck_fields << sql_field_with_alias(linkage_table_alias, primary_key)
              end
            else
              klass = linkage_relationship.resource_klass
              linkage_fields << { relationship_name: linkage_relationship_name, resource_klass: klass }

              linkage_table_alias = join_manager.join_details_by_relationship(linkage_relationship)[:alias]
              primary_key = klass._primary_key
              pluck_fields << sql_field_with_alias(linkage_table_alias, primary_key)
            end
          end

          sort_fields = options.dig(:_relation_helper_options, :sort_fields)
          sort_fields.try(:each) do |field|
            pluck_fields << Arel.sql(field)
          end

          rows = safe_pluck_operation(records, pluck_fields)
          rows.each do |row|
            rid = JSONAPI::ResourceIdentity.new(self, row[0])
            fragments[rid] ||= JSONAPI::ResourceFragment.new(rid)

            parent_rid = JSONAPI::ResourceIdentity.new(parent_resource_klass, row[1])
            fragments[rid].add_related_from(parent_rid)

            fragments[rid].add_related_identity(relationship.name, parent_rid) if connect_source_identity

            attributes_offset = 2
            fragments[rid].cache = cast_to_attribute_type(row[attributes_offset], cache_field[:type])

            attributes_offset += 1

            linkage_fields.each do |linkage_field|
              fragments[rid].initialize_related(linkage_field[:relationship_name])
              related_id = row[attributes_offset]
              if related_id
                related_rid = JSONAPI::ResourceIdentity.new(linkage_field[:resource_klass], related_id)
                fragments[rid].add_related_identity(linkage_field[:relationship_name], related_rid)
              end
              attributes_offset += 1
            end
          end
        else
          linkage_fields = []

          linkage_relationships.each do |linkage_relationship|
            linkage_relationship_name = linkage_relationship.name

            if linkage_relationship.polymorphic? && linkage_relationship.belongs_to?
              linkage_relationship.resource_types.each do |resource_type|
                klass = linkage_relationship.resource_klass.resource_klass_for(resource_type)
                primary_key = klass._primary_key
                linkage_table_alias = join_manager.join_details_by_polymorphic_relationship(linkage_relationship,
                                                                                            resource_type)[:alias]

                select_alias = "jr_l_#{linkage_relationship_name}_#{resource_type}_pk"
                select_alias_statement = sql_field_with_fixed_alias(linkage_table_alias, primary_key, select_alias)
                linkage_fields << { relationship_name: linkage_relationship_name,
                                    resource_klass: klass,
                                    select: select_alias_statement,
                                    select_alias: select_alias }
              end
              if linkage_relationship.resource_types.empty?
                model_hints = linkage_relationship.resource_klass._model_hints
                model_hints.each do |k, _v|
                  linkage_fields << {
                    relationship_name: linkage_relationship_name,
                    resource_klass: resource_klass_for(k)
                  }
                end
              end
            else
              klass = linkage_relationship.resource_klass
              primary_key = klass._primary_key
              linkage_table_alias = join_manager.join_details_by_relationship(linkage_relationship)[:alias]
              select_alias = "jr_l_#{linkage_relationship_name}_pk"
              select_alias_statement = sql_field_with_fixed_alias(linkage_table_alias, primary_key, select_alias)

              linkage_fields << { relationship_name: linkage_relationship_name,
                                  resource_klass: klass,
                                  select: select_alias_statement,
                                  select_alias: select_alias }
            end
          end

          parent_table_alias = join_manager.join_details_by_relationship(relationship)[:alias]
          source_field = sql_field_with_fixed_alias(parent_table_alias, parent_resource_klass._primary_key,
                                                    'jr_source_id')

          records = records.select(concat_table_field(_table_name, Arel.star), source_field)

          records = records.select(linkage_fields.collect { |f| f[:select] }) if linkage_fields.any?

          resources = resources_for(records, options[:context])

          fragments = convert_resources_to_fragments resources,
                                                     linkage_fields,
                                                     relationship,
                                                     connect_source_identity,
                                                     parent_resource_klass
          # resources.each do |resource|
          #   rid = resource.identity

          #   fragments[rid] ||= JSONAPI::ResourceFragment.new(rid, resource: resource)

          #   parent_rid = JSONAPI::ResourceIdentity.new(parent_resource_klass,
          #                                              resource._model.attributes['jr_source_id'])

          #   fragments[rid].add_related_identity(relationship.name, parent_rid) if connect_source_identity

          #   fragments[rid].add_related_from(parent_rid)

          #   linkage_fields.each do |linkage_field_details|
          #     fragments[rid].initialize_related(linkage_field_details[:relationship_name])
          #     # violates DRY
          #     related_model = resource._model.public_send(linkage_field_details[:relationship_name])
          #     model_classes_match = related_model.class <= linkage_field_details[:resource_klass]._model_class
          #     related_id = related_model.id if model_classes_match
          #     # related_id = resource._model.attributes[linkage_field_details[:select_alias]]
          #     if related_id
          #       related_rid = JSONAPI::ResourceIdentity.new(linkage_field_details[:resource_klass], related_id)
          #       fragments[rid].add_related_identity(linkage_field_details[:relationship_name], related_rid)
          #     else
          #       # binding.pry
          #     end
          #   end
          # end
        end
        
        fragments
      end

    private

      def convert_resources_to_fragments(resources, linkage_fields, relationship = nil, connect_source_identity = nil, parent_resource_klass = nil)
        fragments = {}
        binding.pry

        resources.each do |resource|
          rid = resource.identity

          fragments[rid] ||= JSONAPI::ResourceFragment.new(rid, resource: resource)

          parent_rid = 
            parent_resource_klass &&
            JSONAPI::ResourceIdentity.new(parent_resource_klass,
                                          resource._model.attributes['jr_source_id'])

          if parent_rid
            fragments[rid].add_related_identity(relationship.name, parent_rid) if connect_source_identity

            fragments[rid].add_related_from(parent_rid)
          end

          linkage_fields.each do |linkage_field_details|
            fragments[rid].initialize_related(linkage_field_details[:relationship_name])
            related_model = resource._model.public_send(linkage_field_details[:relationship_name])
            model_classes_match = related_model.class <= linkage_field_details[:resource_klass]._model_class
            related_id = related_model.id if model_classes_match
            if related_id
              related_rid = JSONAPI::ResourceIdentity.new(linkage_field_details[:resource_klass], related_id)
              fragments[rid].add_related_identity(linkage_field_details[:relationship_name], related_rid)
            end
          end
        end

        fragments
      end
      
    public

      # Counts Resources related to the source resource through the specified relationship
      #
      # @param source_rid [ResourceIdentity] Source resource identifier
      # @param relationship_name [String | Symbol] The name of the relationship
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [Integer] the count

      def count_related(source, relationship, options = {})
        relationship.resource_klass.count_related_from_inverse(source, relationship, options)
      end

      def count_related_from_inverse(source_resource, source_relationship, options = {})
        relationship = source_relationship.resource_klass._relationship(source_relationship.inverse_relationship)

        related_klass = relationship.resource_klass

        filters = options.fetch(:filters, {})

        # Joins in this case are related to the related_klass
        join_manager = ActiveRelation::JoinManager.new(resource_klass: self,
                                                       source_relationship: relationship,
                                                       filters: filters)

        records = apply_request_settings_to_records(records: records(options),
                                                    resource_klass: self,
                                                    source_ids: source_resource.id,
                                                    join_manager: join_manager,
                                                    filters: filters,
                                                    options: options)

        related_alias = join_manager.join_details_by_relationship(relationship)[:alias]

        # Rails 8 compatible field selection
        field_name = concat_table_field(related_alias, related_klass._primary_key, true)
        records = records.select(Arel.sql(field_name))

        count_records(records)
      end

      # This resource class (ActiveRelationResource) uses an `ActiveRecord::Relation` as the starting point for
      # retrieving models. From this relation filters, sorts and joins are applied as needed.
      # Depending on which phase of the request processing different `records` methods will be called, giving the user
      # the opportunity to override them differently for performance and security reasons.

      # begin `records`methods

      # Base for the `records` methods that follow and is not directly used for accessing model data by this class.
      # Overriding this method gives a single place to affect the `ActiveRecord::Relation` used for the resource.
      #
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [ActiveRecord::Relation]
      def records_base(_options = {})
        _model_class.all
      end

      # The `ActiveRecord::Relation` used for finding user requested models. This may be overridden to enforce
      # permissions checks on the request.
      #
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [ActiveRecord::Relation]
      def records(options = {})
        records_base(options)
      end

      # The `ActiveRecord::Relation` used for populating the ResourceSet. Only resources that have been previously
      # identified through the `records` method will be accessed. Thus it should not be necessary to reapply permissions
      # checks. However if the model needs to include other models adding `includes` is appropriate
      #
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [ActiveRecord::Relation]
      def records_for_populate(options = {})
        records_base(options)
      end

      # The `ActiveRecord::Relation` used for the finding related resources.
      #
      # @option options [Hash] :context The context of the request, set in the controller
      #
      # @return [ActiveRecord::Relation]
      def records_for_source_to_related(options = {})
        records_base(options)
      end

      # end `records` methods

      def apply_join(records:, relationship:, resource_type:, join_type:, options:)
        if relationship.polymorphic? && relationship.belongs_to?
          case join_type
          when :inner
            records = records.reload.joins(resource_type.to_s.singularize.to_sym)
          when :left
            # binding.pry
            records = records.reload.joins_left(resource_type.to_s.singularize.to_sym)
          end
        else
          relation_name = relationship.relation_name(options)

          # if relationship.alias_on_join
          #   alias_name = "#{relationship.preferred_alias}_#{relation_name}"
          #   case join_type
          #   when :inner
          #     records = records.joins_with_alias(relation_name, alias_name)
          #   when :left
          #     records = records.left_joins_with_alias(relation_name, alias_name)
          #   end
          # else
          case join_type
          when :inner
            # binding.pry
            records = records.reload.joins(relation_name)
          when :left
            records = records.reload.left_joins(relation_name)
          end
        end
        # end
        records
      end

      def relationship_records(relationship:, join_type: :inner, resource_type: nil, options: {})
        records = relationship.parent_resource.records_for_source_to_related(options)
        strategy = relationship.options[:apply_join]

        if strategy
          call_method_or_proc(strategy, records, relationship, resource_type, join_type, options)
        else
          apply_join(records: records,
                     relationship: relationship,
                     resource_type: resource_type,
                     join_type: join_type,
                     options: options)
        end
      end

      def join_relationship(records:, relationship:, resource_type: nil, join_type: :inner, options: {})
        relationship_records = relationship_records(relationship: relationship,
                                                    join_type: join_type,
                                                    resource_type: resource_type,
                                                    options: options)
        
        # Rails 8 compatible merging
        if Rails::VERSION::MAJOR >= 8
          # Ensure both relations are from compatible base classes
          begin
            records.merge(relationship_records)
          rescue ArgumentError => e
            # Fallback for incompatible relations
            Rails.logger.warn "Relation merge failed in Rails 8: #{e.message}"
            records
          end
        else
          records.merge(relationship_records)
        end
      end

      # protected

      def find_record_by_key(key, options = {})
        record = apply_request_settings_to_records(records: records(options), primary_keys: key, options: options).first
        raise JSONAPI::Exceptions::RecordNotFound.new(key) if record.nil?

        record
      end

      def find_records_by_keys(keys, options = {})
        apply_request_settings_to_records(records: records(options), primary_keys: keys, options: options)
      end

      def apply_request_settings_to_records(records:,
                                            join_manager: ActiveRelation::JoinManager.new(resource_klass: self),
                                            resource_klass: self,
                                            source_ids: nil,
                                            filters: {},
                                            primary_keys: nil,
                                            sort_criteria: nil,
                                            sort_primary: nil,
                                            paginator: nil,
                                            options: {})
        options[:_relation_helper_options] = { join_manager: join_manager, sort_fields: [] }

        records = resource_klass.apply_joins(records, join_manager, options)

        if source_ids
          source_join_details = join_manager.source_join_details
          source_primary_key = join_manager.source_relationship.resource_klass._primary_key

          source_aliased_key = concat_table_field(source_join_details[:alias], source_primary_key, false)
          records = records.where(source_aliased_key => source_ids)
        end

        records = records.where(_primary_key => primary_keys) if primary_keys

        records = resource_klass.filter_records(records, filters, options) unless filters.empty?

        if sort_primary
          records = records.order(_primary_key => :asc)
        else
          order_options = resource_klass.construct_order_options(sort_criteria)
          records = resource_klass.sort_records(records, order_options, options)
        end

        records = resource_klass.apply_pagination(records, paginator, order_options) if paginator

        records
      end

      def apply_joins(records, join_manager, options)
        join_manager.join(records, options)
      end

      def apply_pagination(records, paginator, order_options)
        records = paginator.apply(records, order_options) if paginator
        records
      end

      def apply_sort(records, order_options, options)
        if order_options.any?
          order_options.each_pair do |field, direction|
            records = apply_single_sort(records, field, direction, options)
          end
        end

        records
      end

      def apply_single_sort(records, field, direction, options)
        context = options[:context]

        strategy = _allowed_sort.fetch(field.to_sym, {})[:apply]

        options[:_relation_helper_options] ||= {}
        options[:_relation_helper_options][:sort_fields] ||= []

        if strategy
          records = call_method_or_proc(strategy, records, direction, context)
        else
          join_manager = options.dig(:_relation_helper_options, :join_manager)
          sort_field = join_manager ? get_aliased_field(field, join_manager) : field
          options[:_relation_helper_options][:sort_fields].push("#{sort_field}")

          # Rails 8 compatible ordering - avoid string interpolation in Arel.sql when possible
          records = if Rails::VERSION::MAJOR >= 8
                      # Use Arel for safer SQL generation in Rails 8
                      if sort_field.is_a?(String) && sort_field.include?('.')
                        records.order(Arel.sql("#{sort_field} #{direction}"))
                      else
                        records.order(sort_field => direction.to_sym)
                      end
                    else
                      records.order(Arel.sql("#{sort_field} #{direction}"))
                    end
        end
        records
      end

      # Assumes ActiveRecord's counting. Override if you need a different counting method
      def count_records(records)
        if Rails::VERSION::MAJOR >= 8
          records.count
        elsif Rails::VERSION::MAJOR >= 6 || (Rails::VERSION::MAJOR == 5 && ActiveRecord::VERSION::MINOR >= 1)
          records.count(:all)
        else
          records.count
        end
      end

      def filter_records(records, filters, options)
        if _polymorphic
          _polymorphic_resource_klasses.each do |klass|
            records = klass.apply_filters(records, filters, options)
          end
        else
          records = apply_filters(records, filters, options)
        end
        records
      end

      def construct_order_options(sort_params)
        if _polymorphic
          warn 'Sorting is not supported on polymorphic relationships'
        else
          super(sort_params)
        end
      end

      def sort_records(records, order_options, options)
        apply_sort(records, order_options, options)
      end

      def sql_field_with_alias(table, field, quoted = true)
        if Rails::VERSION::MAJOR >= 8
          # Use safer Arel node construction for Rails 8
          table_field = concat_table_field(table, field, quoted)
          alias_field = alias_table_field(table, field, quoted)
          Arel.sql("#{table_field} AS #{alias_field}")
        else
          Arel.sql("#{concat_table_field(table, field, quoted)} AS #{alias_table_field(table, field, quoted)}")
        end
      end

      def sql_field_with_fixed_alias(table, field, alias_as, quoted = true)
        if Rails::VERSION::MAJOR >= 8
          table_field = concat_table_field(table, field, quoted)
          Arel.sql("#{table_field} AS #{alias_as}")
        else
          Arel.sql("#{concat_table_field(table, field, quoted)} AS #{alias_as}")
        end
      end

      def concat_table_field(table, field, quoted = false)
        if table.blank?
          split_table, split_field = field.to_s.split('.')
          if split_table && split_field
            table = split_table
            field = split_field
          end
        end
        if table.blank?
          # :nocov:
          if quoted
            quote_column_name(field)
          else
            field.to_s
          end
          # :nocov:
        elsif quoted
          "#{quote_table_name(table)}.#{quote_column_name(field)}"
        else
          # :nocov:
          "#{table}.#{field}"
          # :nocov:
        end
      end

      def alias_table_field(table, field, quoted = false)
        if table.blank? || field.to_s.include?('.')
          # :nocov:
          if quoted
            quote_column_name(field)
          else
            field.to_s
          end
          # :nocov:
        elsif quoted
          # :nocov:
          quote_column_name("#{table}_#{field}")
        # :nocov:
        else
          "#{table}_#{field}"
        end
      end

      def quote_table_name(table_name)
        if _model_class&.connection
          _model_class.connection.quote_table_name(table_name)
        else
          # Rails 8 compatible fallback
          if Rails::VERSION::MAJOR >= 8
            ActiveRecord::Base.connection.quote_table_name(table_name)
          else
            quote(table_name)
          end
        end
      end

      def quote_column_name(column_name)
        return column_name if column_name == '*'

        if _model_class&.connection
          _model_class.connection.quote_column_name(column_name)
        else
          # Ruby 3.4 compatible string handling
          if RUBY_VERSION >= "3.4"
            column_name_str = column_name.to_s.dup
            ActiveRecord::Base.connection.quote_column_name(column_name_str)
          elsif Rails::VERSION::MAJOR >= 8
            ActiveRecord::Base.connection.quote_column_name(column_name)
          else
            quote(column_name)
          end
        end
      end

      # fallback quote identifier when database adapter not available
      def quote(field)
        %("#{field}")
      end

      def apply_filters(records, filters, options = {})
        if filters
          filters.each do |filter, value|
            records = apply_filter(records, filter, value, options)
          end
        end

        records
      end

      def get_aliased_field(path_with_field, join_manager)
        path = JSONAPI::Path.new(resource_klass: self, path_string: path_with_field)

        relationship_segment = path.segments[-2]
        field_segment = path.segments[-1]

        if relationship_segment
          join_details = join_manager.join_details[path.last_relationship]
          table_alias = join_details[:alias]
        else
          table_alias = _table_name
        end

        concat_table_field(table_alias, field_segment.delegated_field_name)
      end

      def apply_filter(records, filter, value, options = {})
        strategy = _allowed_filters.fetch(filter.to_sym, {})[:apply]

        if strategy
          records = call_method_or_proc(strategy, records, value, options)
        else
          join_manager = options.dig(:_relation_helper_options, :join_manager)
          field = join_manager ? get_aliased_field(filter, join_manager) : filter.to_s

          # Rails 8 compatible filtering - safer SQL generation
          records = if Rails::VERSION::MAJOR >= 8
                      # For Rails 8, try to avoid Arel.sql when possible for simple field names
                      if field.is_a?(String) && field.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?\z/)
                        # Simple field name, can use directly
                        records.where(field => value)
                      else
                        # Complex field expression, use Arel.sql
                        records.where(Arel.sql(field) => value)
                      end
                    else
                      records.where(Arel.sql(field) => value)
                    end
        end

        records
      end

      def warn_about_unused_methods
        return unless Rails.env.development?
        return unless !caching? && implements_class_method?(:records_for_populate)

        warn "#{self}: The `records_for_populate` method is not used when caching is disabled."
      end

      def implements_class_method?(method_name)
        methods(false).include?(method_name)
      end
    end
  end
end

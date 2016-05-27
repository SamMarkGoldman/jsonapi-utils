require 'jsonapi/utils/response/formatters'
require 'jsonapi/utils/response/renders'

module JSONAPI
  module Utils
    module Response
      include Renders
      include Formatters

      def filter_params
        @_filter_params ||=
          if params[:filter].is_a?(Hash)
            params[:filter].keys.each_with_object({}) do |resource, hash|
              hash[resource] = params[:filter][resource]
            end
          end
      end

      def sort_params
        @_sort_params ||=
          if params[:sort].present?
            params[:sort].split(',').each_with_object({}) do |criteria, hash|
              order, field = criteria.match(/(\-?)(\w+)/i)[1..2]
              hash[field]  = order == '-' ? :desc : :asc
            end
          end
      end

      private

      def build_response_document(records, options)
        results = JSONAPI::OperationResults.new

        if records.respond_to?(:to_ary)
          @_records = build_collection(records, options)
          results.add_result(JSONAPI::ResourcesOperationResult.new(:ok, @_records, result_options(records, options)))
        else
          @_record = turn_into_resource(records, options)
          results.add_result(JSONAPI::ResourceOperationResult.new(:ok, @_record))
        end

        @_response_document = create_response_document(results)
      end


      def fix_request_options(params, records)
        return if request.method !~ /get/i ||
                  params.nil? ||
                  %w(index show create update destroy).include?(params[:action])
        action = records.respond_to?(:to_ary) ? 'index' : 'show'
        @request.send("setup_#{action}_action", params)
      end

      def result_options(records, options)
        {}.tap do |data|
          if JSONAPI.configuration.default_paginator != :none &&
            JSONAPI.configuration.top_level_links_include_pagination
            data[:pagination_params] = pagination_params(records, options)
          end

          if JSONAPI.configuration.top_level_meta_include_record_count
            data[:record_count] = count_records(records, options)
          end
        end
      end

      def pagination_params(records, options)
        @paginator ||= paginator(params)
        if @paginator && JSONAPI.configuration.top_level_links_include_pagination
          options = {}
          @paginator.class.requires_record_count &&
            options[:record_count] = count_records(records, options)
          @paginator.links_page_params(options)
        else
          {}
        end
      end

      def paginator(params)
        page_params = ActionController::Parameters.new(params[:page])

        @paginator ||=
          if JSONAPI.configuration.default_paginator == :paged
            PagedPaginator.new(page_params)
          elsif JSONAPI.configuration.default_paginator == :offset
            OffsetPaginator.new(page_params)
          end
      end

      def build_collection(records, options = {})
        records = apply_filter(records, options)
        records = apply_pagination(records, options)
        records = apply_sort(records)
        records.respond_to?(:to_ary) ? records.map { |record| turn_into_resource(record, options) } : []
      end

      def turn_into_resource(record, options = {})
        if options[:resource]
          options[:resource].to_s.constantize.new(record, context)
        else
          @request.resource_klass.new(record, context)
        end
      end

      def apply_filter(records, options = {})
        if apply_filter?(records, options)
          records.where(filter_params)
        else
          records
        end
      end

      def apply_filter?(records, options = {})
        params[:filter].present? && records.respond_to?(:where) &&
          (options[:filter].nil? || options[:filter])
      end

      def apply_pagination(records, options = {})
        return records unless apply_pagination?(options)
        pagination = set_pagination(options)

        records =
          if records.is_a?(Array)
            records[pagination[:range]]
          else
            pagination[:paginator].apply(records, nil)
          end
      end

      def apply_sort(records)
        return records unless params[:sort].present?

        if records.is_a?(Array)
          records.sort { |a, b| comp = 0; eval(sort_criteria) }
        elsif records.respond_to?(:order)
          records.order(sort_params)
        end
      end

      def sort_criteria
        sort_params.reduce('') do |sum, hash|
          foo = ["a[:#{hash[0]}]", "b[:#{hash[0]}]"]
          foo.reverse! if hash[1] == :desc
          sum + "comp = comp == 0 ? #{foo.join(' <=> ')} : comp; "
        end
      end

      def set_pagination(options)
        page_params = ActionController::Parameters.new(@request.params[:page])
        if JSONAPI.configuration.default_paginator == :paged
          @_paginator ||= PagedPaginator.new(page_params)
          number = page_params['number'].to_i.nonzero? || 1
          size   = page_params['size'].to_i.nonzero?   || JSONAPI.configuration.default_page_size
          { paginator: @_paginator, range: (number - 1) * size..number * size - 1 }
        elsif JSONAPI.configuration.default_paginator == :offset
          @_paginator ||= OffsetPaginator.new(page_params)
          offset = page_params['offset'].to_i.nonzero? || 0
          limit  = page_params['limit'].to_i.nonzero?  || JSONAPI.configuration.default_page_size
          { paginator: @_paginator, range: offset..offset + limit - 1 }
        else
          {}
        end
      end

      def apply_pagination?(options)
        JSONAPI.configuration.default_paginator != :none &&
          (options[:paginate].nil? || options[:paginate])
      end

      def hash_to_active_record(data, model)
        return data if model.nil?
        coerced = [data].flatten.map { |hash| model.new(hash) }
        data.is_a?(Array) ? coerced : coerced.first
      rescue ActiveRecord::UnknownAttributeError
        if data.is_a?(Array)
          ids = data.map { |e| e[:id] }
          model.where(id: ids)
        else
          model.find_by(id: data[:id])
        end
      end

      def count_records(records, options)
        if options[:count].present?
          options[:count]
        elsif records.is_a?(Array)
          records.length
        else
          records = apply_filter(records, options) if params[:filter].present?
          records.except(:group, :order).count("DISTINCT #{records.table.name}.id")
        end
      end
    end
  end
end
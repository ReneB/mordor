module Mordor
  module Resource
    attr_accessor :_id

    def self.included(base)
      base.extend(ClassMethods)
    end

    def initialize(attributes = {})
      attributes.each do |k,v|
        self.send("#{k}=", v)
      end
    end

    def replace_params(params = {})
      result = {}
      return result unless params
      params.each do |key, value|
        value = replace_type(value)
        key = key.to_s.gsub(/\W|\./, "_")
        result[key] = value
      end
      result
    end

    def replace_type(value)
      case value
      when Hash
        value = replace_params(value)
      when Date, DateTime
        value = value.to_time.getlocal
      when Time
        value = value.getlocal
      when BigDecimal
        value = value.to_f
      when Array
        value = value.map do |val|
          replace_type(val)
        end
      when Integer
      else
        value = value.to_s
      end
      value
    end

    def new?
      return self._id == nil
    end

    def saved?
      return !new?
    end

    def reload
      return unless _id
      res = self.class.get(_id).to_hash.each do |k, v|
        self.send("#{k}=".to_sym, v)
      end
      self
    end

    def save
      unless self._id
        self_hash = self.to_hash
        if timestamp_attribute = self.class.timestamped_attribute
          timestamp_value = self_hash.delete(timestamp_attribute)
          ordered_self_hash = BSON::OrderedHash.new
          ordered_self_hash[timestamp_attribute] = (timestamp_value.nil? || timestamp_value.empty?) ? BSON::Timestamp.new(0, 0) : timestamp_value
          self_hash.each do |key, value|
            ordered_self_hash[key] = value
          end
          self_hash = ordered_self_hash
        end
        insert_id = self.class.collection.insert(self_hash)
        self._id = insert_id
        self.reload
      else
        insert_id = self.update
      end
      saved?
    end

    alias_method :save!, :save

    def update
      insert_id = self.class.collection.update({:_id => self._id}, self.to_hash)
      insert_id
    end

    def collection
      self.class.collection
    end

    def to_hash
      attributes = self.class.instance_variable_get(:@attributes)
      result = {}
      return result unless attributes
      attributes.each do |attribute_name|
        result[attribute_name] = replace_type(self.send(attribute_name))
      end
      result
    end

    def to_json(*args)
      to_hash.merge(:_id => _id).to_json(*args)
    end

    module ClassMethods
      def create(attributes = {})
        resource = self.new(attributes)
        resource.save
        resource
      end

      def all(options = {})
        Collection.new(self, perform_collection_find({}, options))
      end

      def collection
        connection.collection(self.collection_name)
      end

      def collection_name
        klassname = self.to_s.downcase.gsub(/[\/|.|::]/, '_')
        "#{klassname}s"
      end

      def get(id)
        if id.is_a?(String)
          id = BSON::ObjectId.from_string(id)
        end
        if attributes = perform_collection_find_one(:_id => id)
          new(attributes)
        else
          nil
        end
      end

      def connection
        @connection ||= Mordor.connection
      end


      def find_by_id(id)
        get(id)
      end

      def find(query, options = {})
        Collection.new(self, perform_collection_find(query, options))
      end

      def find_by_day(day, options = {})
        case day
        when DateTime
          start = day.to_date.to_time
          end_of_day = (day.to_date + 1).to_time
        when Date
          start = day.to_time
          end_of_day = (day + 1).to_time
        when Time
          start = day.to_datetime.to_date.to_time
          end_of_day = (day.to_date + 1).to_datetime.to_date.to_time
        end
        hash = {:at => {'$gte' => start, '$lt' => end_of_day}}
        cursor = perform_collection_find({:at => {'$gte' => start, '$lt' => end_of_day}}, options)
        Collection.new(self, cursor)
      end

      def timestamped_attribute
        @timestamped_attribute
      end

      def attribute(name, options = {})
        @attributes  ||= []
        @indices     ||= []
        @index_types ||= {}

        @attributes << name unless @attributes.include?(name)
        if options[:index]
          @indices    << name unless @indices.include?(name)
          @index_types[name] = options[:index_type] ? options[:index_type] : Mongo::DESCENDING
        end

        if options[:timestamp]
          raise ArgumentError.new("Only one timestamped attribute is allowed, '#{@timestamped_attribute}' is already timestamped") unless @timestamped_attribute.nil?
          @timestamped_attribute = name
        end

        method_name = options.key?(:finder_method) ? options[:finder_method] : "find_by_#{name}"

        class_eval <<-EOS, __FILE__, __LINE__
          attr_accessor name

          def self.#{method_name}(value, options = {})
            if value.is_a?(Hash)
              raise ArgumentError.new(":value missing from complex query hash") unless value.keys.include?(:value)
              query = {:#{name} => value.delete(:value)}
              query = query.merge(value)
            else
              query = {:#{name} => value}
            end
            col = perform_collection_find(query, options)
            Collection.new(self, col)
          end
        EOS
      end

      private
      def perform_collection_find(query, options = {})
        ensure_indices
        collection.find(query, options)
      end

      def perform_collection_find_one(query, options = {})
        ensure_indices
        collection.find_one(query, options)
      end

      def ensure_indices
        indices.each do |index|
          collection.ensure_index( [ [index.to_s, index_types[index]] ] )
        end
      end

      def indices
        @indices ||= []
      end

      def index_types
        @index_types ||= {}
      end
    end
  end
end

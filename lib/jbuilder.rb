require 'blankslate'
require 'active_support/ordered_hash'
require 'active_support/core_ext/array/access'
require 'active_support/core_ext/enumerable'
require 'active_support/json'
require "yajl"

class JsonWrapper
  def initialize(json_string)
    @json_string = json_string
  end

  # yajl-ruby will check if this method exists and call it if so
  # then append the return value directly onto the output buffer as-is
  # this means that this method is assumed to be returning valid JSON
  def to_json
    @json_string
  end
end

class Jbuilder < BlankSlate
  # Yields a builder and automatically turns the result into a JSON string
  def self.encode
    new._tap { |jbuilder| yield jbuilder }.target!
  end

  def self.encode_with_cache(cache_key)
    Rails.cache.fetch(cache_key) do
      new._tap { |jbuilder| yield jbuilder }.target!
    end    
  end

  define_method(:__class__, find_hidden_method(:class))
  define_method(:_tap, find_hidden_method(:tap))

  def initialize
    @attributes = ActiveSupport::OrderedHash.new
  end

  # Dynamically set a key value pair.
  #
  # Example:
  #
  #   json.set!(:each, "stuff")
  #
  #   { "each": "stuff" }
  #
  # You can also pass a block for nested attributes
  #
  #   json.set!(:author) do |json|
  #     json.name "David"
  #     json.age 32
  #   end
  #
  #   { "author": { "name": "David", "age": 32 } }
  def set!(key, value = nil)
    if block_given?
      _yield_nesting(key) { |jbuilder| yield jbuilder }
    else
      @attributes[key] = value
    end
  end

  # Turns the current element into an array and yields a builder to add a hash.
  #
  # Example:
  #
  #   json.comments do |json|
  #     json.child! { |json| json.content "hello" }
  #     json.child! { |json| json.content "world" }
  #   end
  #
  #   { "comments": [ { "content": "hello" }, { "content": "world" } ]}
  #
  # More commonly, you'd use the combined iterator, though:
  #
  #   json.comments(@post.comments) do |json, comment|
  #     json.content comment.formatted_content
  #   end
  def child!
    @attributes = [] unless @attributes.is_a? Array
    @attributes << _new_instance._tap { |jbuilder| yield jbuilder }.attributes!
  end

  def child_json!(json)
    @attributes = [] unless @attributes.is_a? Array
    @attributes << JsonWrapper.new(json)
  end

  # Turns the current element into an array and iterates over the passed collection, adding each iteration as 
  # an element of the resulting array.
  #
  # Example:
  #
  #   json.array!(@people) do |json, person|
  #     json.name person.name
  #     json.age calculate_age(person.birthday)
  #   end
  #
  #   [ { "name": David", "age": 32 }, { "name": Jamie", "age": 31 } ]
  #
  # If you are using Ruby 1.9+, you can use the call syntax instead of an explicit extract! call:
  #
  #   json.(@people) { |json, person| ... }
  #
  # It's generally only needed to use this method for top-level arrays. If you have named arrays, you can do:
  #
  #   json.people(@people) do |json, person|
  #     json.name person.name
  #     json.age calculate_age(person.birthday)
  #   end  
  #
  #   { "people": [ { "name": David", "age": 32 }, { "name": Jamie", "age": 31 } ] }
  def array!(collection)
    @attributes = [] and return if collection.empty?
    
    keys = collection.select { |el| el.respond_to?(:jbuilder_cache_key) }.
                      map    { |el| el.jbuilder_cache_key }

    cached = if keys.blank? 
      {}
    else
      Rails.cache.read_multi(keys)
    end

    # set the maximum no of cache_writes (reduce the latency penalty we pay per attempt)
    max_cache_writes = 50;

    collection.each do |element|
      if element.respond_to?(:jbuilder_cache_key) 
        key = element.jbuilder_cache_key

        cached_json = cached[key]

        if cached_json.blank?
          cached_json = _new_instance._tap { |jbuilder| yield jbuilder, element }.target!
          if max_cache_writes > 0
            Rails.cache.write(key, cached_json)
            max_cache_writes =- 1
          end 
        end

        child_json! cached_json
      else
        child! do |child|
          yield child, element
        end
      end

    end
  end

  # Extracts the mentioned attributes from the passed object and turns them into attributes of the JSON.
  #
  # Example:
  #
  #   json.extract! @person, :name, :age
  #
  #   { "name": David", "age": 32 }, { "name": Jamie", "age": 31 }
  #
  # If you are using Ruby 1.9+, you can use the call syntax instead of an explicit extract! call:
  #
  #   json.(@person, :name, :age)
  def extract!(object, *attributes)
    attributes.each do |attribute|
      __send__ attribute, object.send(attribute)
    end
  end

  if RUBY_VERSION > '1.9'
    def call(*args)
      case
      when args.one?
        array!(args.first) { |json, element| yield json, element }
      when args.many?
        extract!(*args)
      end
    end
  end

  # Returns the attributes of the current builder.
  def attributes!
    @attributes
  end
  
  # Encodes the current builder as JSON.
  def target!
    Yajl::Encoder.encode @attributes
  end


  private
    def method_missing(method, *args)
      case
      # json.comments @post.comments { |json, comment| ... }
      # { "comments": [ { ... }, { ... } ] }
      when args.one? && block_given?
        _yield_iteration(method, args.first) { |child, element| yield child, element }

      # json.age 32
      # { "age": 32 }
      when args.length == 1
        set! method, args.first

      # json.comments { |json| ... }
      # { "comments": ... }
      when args.empty? && block_given?
        _yield_nesting(method) { |jbuilder| yield jbuilder }
      
      # json.comments(@post.comments, :content, :created_at)
      # { "comments": [ { "content": "hello", "created_at": "..." }, { "content": "world", "created_at": "..." } ] }
      when args.many? && args.first.is_a?(Enumerable)
        _inline_nesting method, args.first, args.from(1)

      # json.author @post.creator, :name, :email_address
      # { "author": { "name": "David", "email_address": "david@loudthinking.com" } }
      when args.many?
        _inline_extract method, args.first, args.from(1)
      end
    end

    # Overwrite in subclasses if you need to add initialization values
    def _new_instance
      __class__.new
    end

    def _yield_nesting(container)
      set! container, _new_instance._tap { |jbuilder| yield jbuilder }.attributes!
    end

    def _inline_nesting(container, collection, attributes)
      __send__(container) do |parent|
        parent.array!(collection) and return if collection.empty?
        
        collection.each do |element|
          parent.child! do |child|
            attributes.each do |attribute|
              child.__send__ attribute, element.send(attribute)
            end
          end
        end
      end
    end
    
    def _yield_iteration(container, collection)
      __send__(container) do |parent|
        parent.array!(collection) do |child, element|
          yield child, element
        end
      end
    end
    
    def _inline_extract(container, record, attributes)
      __send__(container) { |parent| parent.extract! record, *attributes }
    end
end

require "jbuilder_template" if defined?(ActionView::Template)

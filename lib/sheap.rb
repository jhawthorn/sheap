# frozen_string_literal: true

require "objspace"
require "fileutils"
require "json"

class Sheap
  def self.reload!
    load __FILE__
  end

  def initialize
    @dir = File.expand_path("sheap")
    @idx = 0
    FileUtils.mkdir_p(@dir)
  end

  module Collection
    def class_named(name)
      objects.select do |obj|
        obj.json.include?(name) &&
          obj.type_str == "CLASS" &&
          obj.name == name
      end
    end

    def instances_of(klass)
      addr = klass.address
      objects.select do |obj|
        obj.json.include?(addr) &&
          obj.class_addr == addr
      end
    end

    def of_type(type)
      type = type.to_s.upcase
      objects.select { |o| o.type_str == type }
    end
  end

  class Diff
    include Collection

    attr_reader :before, :after
    def initialize(before, after)
      @before = Heap.wrap(before)
      @after = Heap.wrap(after)
    end

    def retained
      @retained ||= calculate_retained
    end
    alias objects retained

    def inspect
      "#<#{self.class} (#{objects.size} objects)>"
    end

    private

    def calculate_retained
      set = Set.new
      @after.objects.each do |obj|
        set.add(obj)
      end
      @before.each_object do |obj|
        set.delete(obj)
      end
      set.to_a
    end
  end

  class << self
    def instance
      @instance ||= new
    end

    def snapshot
      instance.snapshot
    end
  end

  EMPTY_ARRAY = [].freeze

  class HeapObject
    attr_reader :heap, :json

    def initialize(heap, json)
      @heap = heap
      @json = json
    end

    def type_str
      @json[/"type":"([A-Z]+)"/, 1]
    end

    def root?
      @json.include?('"type":"ROOT"')
    end

    def address
      @json[/"address":"(0x[0-9a-f]+)"/, 1] || @json[/"root":"([a-z_]+)"/, 1]
    end

    def referenced_addrs
      str = @json[/"references":\[([",0-9a-fx ]+)\]/, 1]
      if str
        str.tr('"', '').split(", ")
      else
        EMPTY_ARRAY
      end
    end

    def references
      referenced_addrs.map do |addr|
        @heap.at(addr)
      end
    end

    def inverse_references
      @heap.inverse_references[address] || EMPTY_ARRAY
    end

    def data
      JSON.parse(@json)
    end

    def memsize
      @json[/"memsize":(\d+),/, 1].to_i
    end

    def class_addr
      @json[/"class":"(0x[0-9a-f]+)"/, 1]
    end

    def imemo_type
      @json[/"imemo_type":"([a-z_]+)"/, 1]
    end

    def struct
      @json[/"struct":"([^"]+)"/, 1]
    end

    def wb_protected?
      @json.include?('"wb_protected":true')
    end

    def old?
      @json.include?('"old":true')
    end

    def name
      data["name"]
    end

    def klass
      @heap.at(class_addr)
    end

    def instances
      raise unless type_str == "CLASS"
      heap.instances_of(self)
    end

    def inspect
      type_str = self.type_str
      s = +"<#{type_str} #{address}"

      case type_str
      when "CLASS"
        s << " " << (name || "(anonymous)")
      when "MODULE"
        s << " " << (name || "(anonymous)")
      when "STRING"
        s << " " << data["value"].inspect
      when "IMEMO"
        s << " " << (imemo_type || "unknown")
      when "OBJECT"
        s << " " << (klass.name || "(#{klass.address})")
      when "DATA"
        s << " " << struct.to_s
      end

      refs = referenced_addrs
      unless refs.empty?
        s << " (#{referenced_addrs.size} refs)"
      end

      s << ">"
    end

    def value
      data["value"]
    end

    def file
      data["file"]
    end

    def line
      data["line"]
    end

    def location
      f = file
      "#{f}:#{line}" if f
    end

    def frozen?
      @json.include?('"frozen":true')
    end

    def eql?(other)
      if @heap.equal?(other.heap)
        @json == other.json
      else
        address == other.address &&
          type_str == other.type_str
      end
    end
    alias_method :==, :eql?

    def references_address?(addr)
      @json.include?(addr) && referenced_addrs.include?(addr)
    end

    def hash
      address.hash
    end
  end

  class Heap
    include Collection

    attr_reader :filename

    def initialize(filename)
      @filename = filename
    end

    def each_object
      return enum_for(__method__) unless block_given?

      open_file do |file|
        file.each_line do |json|
          yield HeapObject.new(self, json)
        end
      end
    end

    def open_file(&block)
      # FIXME: look for magic header
      if filename.end_with?(".gz")
        require "zlib"
        Zlib::GzipReader.open(filename, &block)
      else
        File.open(filename, &block)
      end
    end

    def objects
      @objects ||= each_object.to_a
    end

    def objects_by_addr
      @objects_by_addr ||=
        begin
          hash = {}
          objects.each do |obj|
            hash[obj.address] = obj
          end
          hash.freeze
        end
    end

    def inverse_references
      @inverse_references ||=
        begin
          hash = {}
          objects.each do |obj|
            obj.referenced_addrs.uniq.each do |addr|
              next if addr == obj.address
              hash[addr] ||= []
              hash[addr] << obj
            end
          end
          hash.freeze
        end
    end

    def roots
      of_type("ROOT")
    end

    # finds a path from `start_address` through the inverse_references hash
    # and so the end_address will be the object that's closer to the root
    def find_path(start_addresses, end_addresses = nil)
      if end_addresses.nil?
        end_addresses = start_addresses
        start_addresses = roots
      end
      start_addresses = Array(start_addresses)
      end_addresses = Array(end_addresses)

      q = start_addresses.map{|x| [x] }

      visited = Set.new
      while !q.empty?
        current_path = q.shift
        current_address = current_path.last

        if end_addresses.include?(current_address)
          return current_path.map{|addr| addr}
        end

        if !visited.include?(current_address)
          visited.add(current_address)

          current_references = current_address.references

          current_references.each do |obj|
            q.push([*current_path, obj])
          end
        end
      end
      nil
    end

    def at(addr)
      objects_by_addr[addr]
    end

    def inspect
      "#<#{self.class} (#{objects.size} objects)>"
    end

    def self.wrap(heap)
      self === heap ? heap : new(heap)
    end
  end

  # A representation of the heap in which objects are organized in layers
  # based on their references. The first layer (depth 0) contains the root objects,
  # the next layer (depth 1) contains the objects that are referenced by the root objects,
  # and so on. The depth of an object is the length of the shortest path from the
  # object to a root object.
  class AcyclicHeap
    attr_reader :heap, :layers

    def initialize(heap)
      @heap = heap
      @layers = build_layers
    end

    def depth_of(obj)
      layers.index { |layer| layer.include?(obj) }
    end

    # All of the deeper objects whose path to the root passes through the given object.
    def referenced_through(object)
      cumulative_refs = Set.new
      unprocessed_refs = Set.new

      current_ref = object
      loop do
        depth_of_current_ref = depth_of(current_ref)
        current_ref.references.each do |ref|
          ref_depth = depth_of(ref)
          next if ref_depth && ref_depth <= depth_of_current_ref
          next if cumulative_refs.include?(ref) || unprocessed_refs.include?(ref)

          unprocessed_refs << ref
        end

        break if unprocessed_refs.empty?
        current_ref = unprocessed_refs.first.tap { |o| unprocessed_refs.delete(o) } # pop
        cumulative_refs << current_ref
      end

      cumulative_refs
    end

    private

    def build_layers
      remaining_objects = Set.new(heap.objects)
      root_objects = Set.new(remaining_objects.select(&:root?))
      remaining_objects.subtract(root_objects)

      layers = [root_objects]
      loop do
        previous_layer = layers.last
        next_layer = Set.new

        previous_layer.map(&:references).flatten.each do |obj|
          next unless remaining_objects.include?(obj)
          next_layer << obj
          remaining_objects.delete(obj)
        end
        break if next_layer.size == 0
        layers << next_layer
      end

      layers
    end
  end
end

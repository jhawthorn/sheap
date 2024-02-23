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
      filter do |obj|
        obj.json.include?(name) &&
          obj.type_str == "CLASS" &&
          obj.name == name
      end
    end

    def instances_of(klass)
      addr = klass.address
      filter do |obj|
        obj.json.include?(addr) &&
          obj.class_addr == addr
      end
    end

    def of_type(type)
      type = type.to_s.upcase
      filter { |o| o.json.include?(type) && o.type_str == type }
    end

    def of_imemo_type(type)
      type = type.to_s.downcase
      filter { |o| o.json.include?(type) && o.imemo_type == type }
    end

    def classes; of_type("CLASS"); end
    def icasses; of_type("ICLASS"); end
    def modules; of_type("MODULE"); end
    def imemos; of_type("IMEMO"); end

    def strings; of_type("STRING"); end
    def hashes; of_type("HASH"); end
    def arrays; of_type("ARRAY"); end

    def plain_objects; of_type("OBJECT"); end
    def structs; of_type("STRUCT"); end
    def datas; of_type("DATA"); end
    def files; of_type("FILE"); end

    def regexps; of_type("REGEXP"); end
    def matches; of_type("MATCH"); end

    def bignums; of_type("BIGNUM"); end
    def symbols; of_type("SYMBOL"); end
    def floats; of_type("FLOAT"); end
    def rationals; of_type("RATIONAL"); end
    def complexes; of_type("COMPLEX"); end

    # imemo types
    def iseqs; of_imemo_type("iseq"); end
    def callcaches; of_imemo_type("callcache"); end
    def constcaches; of_imemo_type("constcache"); end
    def callinfos; of_imemo_type("callinfo"); end
    def crefs; of_imemo_type("cref"); end
    def ments; of_imemo_type("ment"); end
  end

  class Diff
    include Collection

    attr_reader :before, :after, :later
    def initialize(before, after, later = nil)
      @before = Heap.wrap(before)
      @after = Heap.wrap(after)
      @later = Heap.wrap(later) if later
    end

    def retained
      @retained ||= HeapObjectCollection.new(calculate_retained, @after)
    end
    alias objects retained

    def filter(&block)
      retained.filter(&block)
    end

    def inspect
      "#<#{self.class} (#{objects.size} objects)>"
    end

    private

    def calculate_retained
      set = Set.new
      @after.objects.each do |obj|
        set.add(obj)
      end
      @before.objects.each do |obj|
        set.delete(obj)
      end
      if @later
        later_set = Set.new(@later.objects)
        set.select! do |obj|
          later_set.include?(obj)
        end
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

  class HeapObjectCollection
    include Enumerable
    include Collection

    attr_reader :heap, :objects

    def initialize(objects, heap = nil)
      objects = objects.to_a unless objects.instance_of?(Array)
      @objects = objects
      @heap = heap || objects.first&.heap
    end

    def filter(&block)
      HeapObjectCollection.new(@objects.select(&block), @heap)
    end
    alias select filter

    def sample(n = nil)
      if n
        HeapObjectCollection.new(@objects.sample(n))
      else
        @objects.sample
      end
    end

    def last(n = nil)
      if n
        HeapObjectCollection.new(@objects.last(n))
      else
        objects.last
      end
    end

    def each(&block)
      @objects.each(&block)
    end

    def length
      @objects.length
    end
    alias size length
    def count(&block)
      @objects.count(&block)
    end

    def pretty_print(q)
      q.group(1, '[', ']') {
        if size <= 20
          q.seplist(self) {|v|
            q.pp v
          }
        else
          preview = 4
          q.seplist(first(preview)) {|v|
            q.pp v
          }
          q.comma_breakable
          q.text "... (#{size - preview} more)"
        end
      }
    end

    def inspect
      "#<#{self.class} (#{size} objects)>"
    end

    def to_a
      @objects
    end
    alias to_ary to_a
  end

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
      HeapObjectCollection.new(
        referenced_addrs.map do |addr|
          @heap.at(addr)
        end,
        heap
      )
    end

    def inverse_references
      HeapObjectCollection.new(
        (@heap.inverse_references[address] || EMPTY_ARRAY),
        heap
      )
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

    def superclass
      heap.at(data["superclass"])
    end

    def inspect
      type_str = self.type_str
      s = +"<#{type_str} #{address} #{inspect_hint}>"
    end

    def inspect_hint
      s = +""
      case type_str
      when "CLASS"
        s << (name || "(anonymous)")
      when "MODULE"
        s << (name || "(anonymous)")
      when "STRING"
        s << data["value"].inspect
      when "IMEMO"
        s << (imemo_type || "unknown")
      when "OBJECT"
        s << (klass.name || "(#{klass.address})")
      when "DATA"
        s << struct.to_s
      end

      refs = referenced_addrs
      unless refs.empty?
        s << " (#{referenced_addrs.size} refs)"
      end

      s
    end

    def pretty_print(q)
      current_depth = q.current_group.depth
      q.group(1, "#<#{type_str}", '>') do
        q.text " "
        q.text address
        if current_depth <= 1
          data = self.data
          attributes = data.keys - ["address"]
          q.seplist(attributes, lambda { q.text ',' }) {|v|
            q.breakable
            q.text v
            q.text "="
            q.group(1) {
              q.breakable ''
              case v
              when "class"
                q.pp klass
              when "superclass"
                q.pp superclass
              when "flags"
                q.text flags.keys.join("|")
              when "references"
                q.text "(#{referenced_addrs.size} refs)"
              else
                q.pp data[v]
              end
            }
          }
        else
          q.breakable
          q.text inspect_hint
        end
      end
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

    def method_missing(name, *args)
      if value = data[name.to_s]
        value
      else
        super
      end
    end

    def respond_to_missing?(name, *)
      data.key?(name.to_s) || super
    end

    def [](key)
      data[key.to_s]
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
      @objects ||= HeapObjectCollection.new(each_object.to_a, self)
    end

    def filter(&block)
      objects.filter(&block)
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
end

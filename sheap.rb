# frozen_string_literal: true

require "objspace"
require "fileutils"
require "json"

class Sheap
  def initialize
    @dir = File.expand_path("sheap")
    @idx = 0
    FileUtils.mkdir_p(@dir)
  end

  def snapshot(gc: true)
    3.times { GC.start } if gc

    output = File.join(@dir, "snapshot-#{@idx}.dump")
    File.open(output, "w") do |file|
      ObjectSpace.dump_all(output: file)
    end
    @idx += 1
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
      @json[/"imemo_type":"([a-z]+)"/, 1]
    end

    def struct
      @json[/"struct":"([a-zA-Z]+)"/, 1]
    end

    def name
      data["name"]
    end

    def klass
      @heap.at(class_addr)
    end

    def inspect
      type_str = self.type_str
      s = +"<#{type_str} #{address}"

      case type_str
      when "CLASS"
        s << " " << name
      when "MODULE"
        s << " " << name
      when "STRING"
        s << " " << data["value"].inspect
      when "IMEMO"
        s << " " << (imemo_type || "unknown")
      when "OBJECT"
        s << " " << klass.name
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
      "#{file}:#{line}"
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
    attr_reader :filename

    def initialize(filename)
      @filename = filename
    end

    def each_object
      return enum_for(__method__) unless block_given?

      File.open(filename) do |file|
        file.each_line do |json|
          yield HeapObject.new(self, json)
        end
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

    def at(addr)
      objects_by_addr[addr]
    end

    def of_type(type)
      type = type.to_s.upcase
      objects.select { |o| o.type_str == type }
    end
  end
end

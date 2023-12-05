# frozen_string_literal: true

require "test_helper"

class TestSheap < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Sheap::VERSION
  end

  def test_diff
    run_ruby(<<~RUBY)
      require "objspace"
      GC.start
      $arr = []
      ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))
      10_000.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot2.dump", "w"))
    RUBY

    before = Sheap::Heap.new("tmp/snapshot1.dump")
    after  = Sheap::Heap.new("tmp/snapshot2.dump")

    diff = Sheap::Diff.new(before, after)
    assert_includes (10000..10500), diff.objects.size

    arrays = diff.of_type("ARRAY")
    assert_includes (10000..10500), arrays.count

    big_array = arrays.flat_map(&:inverse_references).tally.sort_by(&:last).last.first

    assert_equal 10_000, big_array.data["length"]
    assert_equal 10_000, big_array.references.size
  end

  def run_ruby(code)
    system("ruby", "--disable-gems", "-e", code)
  end
end

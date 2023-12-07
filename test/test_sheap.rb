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

    diff = Sheap::Diff.new("tmp/snapshot1.dump", "tmp/snapshot2.dump")
    assert_includes (10000..10500), diff.objects.size

    arrays = diff.of_type("ARRAY")
    assert_includes (10000..10500), arrays.count

    big_array = arrays.flat_map(&:inverse_references).tally.sort_by(&:last).last.first

    assert_equal 10_000, big_array.data["length"]
    assert_equal 10_000, big_array.references.size
  end

  def test_paths_to_root
    run_ruby(<<~RUBY)
      require "objspace"
      GC.start
      $arr = []
      1337.times { $arr << [] }
      ObjectSpace.dump_all(output: open("tmp/snapshot1.dump", "w"))
    RUBY

    heap = Sheap::Heap.new("tmp/snapshot1.dump")
    assert heap.roots.size > 0

    big_array = heap.of_type("ARRAY").detect{|x| x.data["length"] == 1_337 }
    assert big_array

    small_array = big_array.references.sample

    path = heap.find_path(small_array)
    assert_equal 3, path.size
    assert path[0].root?
    assert_equal big_array, path[1]
    assert_equal small_array, path[2]
  end

  def run_ruby(code)
    system("ruby", "--disable-gems", "-e", code)
  end
end

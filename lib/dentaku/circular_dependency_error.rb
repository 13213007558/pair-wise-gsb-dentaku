require 'tsort'
require 'dentaku/exceptions'

module Dentaku
  class CircularDependencyError < ::TSort::Cyclic
    include Error

    def initialize(names)
      @names = Array(names)
      super("cyclic value dependency: #{@names.join(' -> ')}")
    end

    def names
      @names.dup
    end
  end
end

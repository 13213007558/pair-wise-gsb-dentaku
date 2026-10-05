module Dentaku
  module TypeChecker
    # One contradictory set of constraints found while checking.
    #
    #   message          -- human readable explanation
    #   expected/actual  -- the two resolved types involved
    #   sites            -- Use records pointing at source positions
    #   formula          -- which formula of a batch, if known
    Conflict = Struct.new(:message, :expected, :actual, :sites, :formula,
                          keyword_init: true) do
      def ranges
        sites.map(&:range).compact
      end
    end

    # A place where an unknown type (no declaration / no signature) affects
    # the result. Explains why a result cannot be fully determined without
    # ever evaluating a function to guess its type.
    Unknown = Struct.new(:reason, :name, :range, :sites, :formula,
                         keyword_init: true)
  end
end

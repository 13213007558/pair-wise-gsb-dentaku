require 'tsort'

module Dentaku
  class DependencyResolver
    include TSort

    def self.find_resolve_order(vars_to_dependencies_hash, case_sensitive = false)
      self.new(vars_to_dependencies_hash, case_sensitive).sort
    end

    # Tarjan's strongly connected components, iterative so a large dependency
    # graph cannot blow the Ruby stack. Components are returned in reverse
    # topological order (sources first, matching tsort's resolve order).
    def self.strongly_connected_components(vars_to_dependencies_hash, case_sensitive = false)
      new(vars_to_dependencies_hash, case_sensitive).strongly_connected_components
    end

    def initialize(vars_to_dependencies_hash, case_sensitive = false)
      @case_sensitive = case_sensitive
      @key_mapping = Hash[vars_to_dependencies_hash.keys.map { |k| [normalized_name(k), k] }]
      # normalize variables and their dependencies alike so child lookups match
      @vars_to_deps = Hash[vars_to_dependencies_hash.map { |k, v| [normalized_name(k), v.map { |d| normalized_name(d) }] }]
    end

    def sort
      tsort.map { |k| @key_mapping.fetch(k, k) }
    end

    def strongly_connected_components
      index = 0
      indices = {}
      lowlink = {}
      stack = []
      on_stack = {}
      components = []

      @vars_to_deps.each_key do |root|
        next if indices.key?(root)

        work = [[root, 0]]
        until work.empty?
          node, edge_position = work.last
          if edge_position.zero?
            indices[node] = index
            lowlink[node] = index
            index += 1
            stack.push(node)
            on_stack[node] = true
          end

          children = @vars_to_deps.fetch(node, [])
          if edge_position < children.length
            child = children[edge_position]
            work.last[1] += 1
            if !@vars_to_deps.key?(child)
              # edge to a node outside the graph: ignore for SCC purposes
            elsif !indices.key?(child)
              work << [child, 0]
            elsif on_stack[child]
              lowlink[node] = [lowlink[node], indices[child]].min
            end
          else
            forms_component = lowlink[node] == indices[node]
            if lowlink[node] == indices[node]
              component = []
              loop do
                member = stack.pop
                on_stack[member] = false
                component << member
                break if member == node
              end
              components << component
            end
            work.pop
            parent_frame = work.last
            if parent_frame && !forms_component
              parent = parent_frame[0]
              lowlink[parent] = [lowlink[parent], lowlink[node]].min
            end
          end
        end
      end

      components.map { |component| component.map { |k| @key_mapping.fetch(k, k) } }
    end

    def tsort_each_node(&block)
      @vars_to_deps.each_key(&block)
    end

    def tsort_each_child(node, &block)
      @vars_to_deps.fetch(node.to_s, []).each(&block)
    end

    private

    def normalized_name(variable_name)
      @case_sensitive ? variable_name.to_s : variable_name.to_s.downcase
    end
  end
end

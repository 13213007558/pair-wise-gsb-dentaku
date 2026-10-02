require 'spec_helper'
require 'dentaku/dependency_resolver'

describe Dentaku::DependencyResolver do
  it 'sorts expressions in dependency order' do
    dependencies = {"first" => ["second"], "second" => ["third"], "third" => []}
    expect(described_class.find_resolve_order(dependencies)).to eq(
      ["third", "second", "first"]
    )
  end

  describe '.strongly_connected_components' do
    it 'puts every acyclic node in its own component' do
      graph = { 'a' => ['b'], 'b' => ['c'], 'c' => [] }
      components = described_class.strongly_connected_components(graph)
      expect(components.sort).to contain_exactly(['a'], ['b'], ['c'])
    end

    it 'groups a two-node dependency cycle' do
      graph = { 'a' => ['b'], 'b' => ['a'], 'c' => ['a'] }
      components = described_class.strongly_connected_components(graph)
      cycle = components.find { |component| component.length == 2 }
      expect(cycle.sort).to eq(['a', 'b'])
      expect(components).to include(['c'])
    end

    it 'detects a self loop as a cyclic component' do
      graph = { 'a' => ['a', 'b'], 'b' => [] }
      components = described_class.strongly_connected_components(graph)
      expect(components).to contain_exactly(['a'], ['b'])
    end

    it 'keeps independent cycles separate' do
      graph = { 'a' => ['b'], 'b' => ['a'], 'c' => ['d'], 'd' => ['c'] }
      components = described_class.strongly_connected_components(graph)
      expect(components.length).to eq(2)
      expect(components.flatten.sort).to eq(%w[a b c d])
    end

    it 'groups a larger mutually dependent component' do
      graph = { 'x' => ['y'], 'y' => ['z'], 'z' => ['x'] }
      components = described_class.strongly_connected_components(graph)
      expect(components.length).to eq(1)
      expect(components.first.sort).to eq(%w[x y z])
    end
  end

  it 'handles case differences' do
    dependencies = {"FIRST" => ["second"], "SeCoNd" => ["third"], "THIRD" => []}
    expect(described_class.find_resolve_order(dependencies)).to eq(
      ["THIRD", "SeCoNd", "FIRST"]
    )
  end

  it 'sorts mixed-case expressions in dependency order when case-sensitive' do
    dependencies = {"TopLevel" => ["MidLevel"], "MidLevel" => ["BottomLevel"], "BottomLevel" => []}
    expect(described_class.find_resolve_order(dependencies, true)).to eq(
      ["BottomLevel", "MidLevel", "TopLevel"]
    )
  end

  it 'treats variables that differ only in case as distinct when case-sensitive' do
    dependencies = {"foo" => ["FOO"], "FOO" => []}
    expect(described_class.find_resolve_order(dependencies, true)).to eq(
      ["FOO", "foo"]
    )
  end
end

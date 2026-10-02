require "bigdecimal"
require "concurrent"
require "dentaku/calculator"
require "dentaku/version"

module Dentaku
  @enable_ast_caching = false
  @enable_dependency_order_caching = false
  @enable_identifier_caching = false
  @aliases = {}

  def self.evaluate(expression, data = {}, &block)
    calculator.value.evaluate(expression, data, &block)
  end

  def self.evaluate!(expression, data = {}, &block)
    calculator.value.evaluate!(expression, data, &block)
  end

  def self.evaluate_with_gradient(expression, data = {}, variables = nil, &block)
    calculator.value.evaluate_with_gradient(expression, data, variables, &block)
  end

  def self.evaluate_with_gradient!(expression, data = {}, variables = nil)
    calculator.value.evaluate_with_gradient!(expression, data, variables)
  end

  class << self
    alias_method :evaluate_gradient, :evaluate_with_gradient
    alias_method :evaluate_gradient!, :evaluate_with_gradient!
  end

  def self.enable_caching!
    enable_ast_cache!
    enable_dependency_order_cache!
    enable_identifier_cache!
  end

  def self.enable_ast_cache!
    @enable_ast_caching = true
  end

  def self.cache_ast?
    @enable_ast_caching
  end

  def self.enable_dependency_order_cache!
    @enable_dependency_order_caching = true
  end

  def self.cache_dependency_order?
    @enable_dependency_order_caching
  end

  def self.enable_identifier_cache!
    @enable_identifier_caching = true
  end

  def self.cache_identifier?
    @enable_identifier_caching
  end

  def self.aliases
    @aliases
  end

  def self.aliases=(hash)
    @aliases = hash
  end

  def self.calculator
    @calculator ||= Concurrent::ThreadLocalVar.new { Dentaku::Calculator.new }
  end
end

def Dentaku(expression, data = {})
  Dentaku.evaluate(expression, data)
end

def Dentaku!(expression, data = {})
  Dentaku.evaluate!(expression, data)
end

# frozen_string_literal: true

require 'debug'
require 'typeprof'
require 'prism'
require_relative "minify/version"

module Ruby
  module Minify
    class Error < StandardError; end
    class MinifyError < Error; end

    def read_path(path)
      @path = path
      @file = File.read(path)
      @cache = SpecifyCache.new

      self
    end

    def minify
      # result = Prism.parse(@file)
      nodes = TypeProf::Core::AST.parse_rb(@path, @file)

      # raise MinifyError unless result.errors.empty?

      @result = rebuild(nodes).join("\n")

      debugger

      self
    end

    def rebuild(nodes)
      nodes.body.stmts.map do |subnode|
        rebuild_node(subnode)
      end.reject(&:empty?)
    end

    def rebuild_node(subnode)
      case subnode
      when TypeProf::Core::AST::CallNode
        # 中置記法の場合の特化
        if middle_method?(subnode.mid)
          "#{rebuild_node(subnode.recv)}#{subnode.mid}#{rebuild_node(subnode.positional_args.first)}"
        elsif with_block_method?(subnode)
          if !subnode.block_body.nil?
            "#{subnode.recv.nil? ? '' : "#{rebuild_node(subnode.recv)}."}#{subnode.mid}#{subnode.positional_args.empty? ? '' : "(#{subnode.positional_args.map{rebuild_node(_1)}.join(',')})"}{|#{subnode.block_f_args.join(',')}|#{rebuild_statement(subnode.block_body)}}"
          elsif !subnode.block_pass.nil?
            "#{subnode.recv.nil? ? '' : "#{rebuild_node(subnode.recv)}."}#{subnode.mid}#{subnode.positional_args.empty? ? '' : "(#{subnode.positional_args.map{rebuild_node(_1)}.join(',')})"}(&#{rebuild_node(subnode.block_pass)})"
          end
        elsif subnode.mid == '[]'.to_sym
          "#{rebuild_node(subnode.recv)}[#{subnode.positional_args.map{rebuild_node(_1)}.join(',')}]"
        elsif subnode.mid == '[]='.to_sym
          "#{rebuild_node(subnode.recv)}[#{rebuild_node(subnode.positional_args.first)}]=#{subnode.positional_args[1..].map{rebuild_node(_1)}.join}"
        elsif subnode.mid == '!'.to_sym
          "!#{rebuild_node(subnode.recv)}"
        else
          "#{subnode.recv.nil? ? '' : "#{rebuild_node(subnode.recv)}."}#{subnode.mid}#{subnode.positional_args.empty? ? '' : "(#{subnode.positional_args.map{rebuild_node(_1)}.join(',')})"}"
        end
      when TypeProf::Core::AST::DefNode
        if subnode.req_positionals.empty?
          "def #{subnode.mid}\n#{rebuild_statement(subnode.body)}\nend"
        else
          "def #{subnode.mid}(#{subnode.req_positionals.join(',')})#{rebuild_statement(subnode.body)}\nend"
        end
      when TypeProf::Core::AST::YieldNode
        "yield #{subnode.positional_args.map{rebuild_node(_1)}.join(',')}"
      when TypeProf::Core::AST::IfNode
        if subnode.else.nil?
          "#{rebuild_statement(subnode.then)} if #{rebuild_node(subnode.cond)}"
        else
          "#{rebuild_node(subnode.cond)} ? #{rebuild_statement(subnode.then)}:#{rebuild_statement(subnode.else)}"
        end
      when TypeProf::Core::AST::UnlessNode
        if subnode.else.nil?
          "!(#{rebuild_node(subnode.cond)}) ? #{rebuild_statement(subnode.then)}:()"
        else
          "!(#{rebuild_node(subnode.cond)}) ? #{rebuild_statement(subnode.then)}:#{rebuild_statement(subnode.else)}"
        end
      when TypeProf::Core::AST::CaseNode
        body = "case #{rebuild_node(subnode.pivot)}\n" + subnode.clauses.zip(subnode.whens).map do |c, w|
          "when #{rebuild_node(w)}\n#{rebuild_statement(c)}\n"
        end.join
        if !subnode.else_clause.nil?
          body += "else\n#{rebuild_statement(subnode.else_clause)}\n"
        end
        body += 'end'
      when TypeProf::Core::AST::ReturnNode
        case subnode.arg
        when TypeProf::Core::AST::DummyNilNode
          '()'
        else
          "#{rebuild_node(subnode.arg)}"
        end
      when TypeProf::Core::AST::TrueNode
        '!!1'
      when TypeProf::Core::AST::FalseNode
        '!1'
      when TypeProf::Core::AST::OperatorNode
        # TODO
        # debugger
      when TypeProf::Core::AST::ClassNode
        [
          "class #{subnode.cpath.cname}#{subnode.superclass_cpath ? "<#{subnode.superclass_cpath.cname}" : ''}",
          rebuild_statement(subnode.body),
          'end'
        ].compact.join("\n")
      when TypeProf::Core::AST::ModuleNode
        "module #{subnode.cpath.cname}\n#{rebuild_statement(subnode.body)}\nend"
      when TypeProf::Core::AST::SelfNode
        'self'
      when TypeProf::Core::AST::AndNode
        "#{rebuild_node(subnode.e1)}&&#{rebuild_node(subnode.e2)}"
      when TypeProf::Core::AST::OrNode
        "#{rebuild_node(subnode.e1)}||#{rebuild_node(subnode.e2)}"
      when TypeProf::Core::AST::LocalVariableReadNode
        subnode.var.to_s
      when TypeProf::Core::AST::LocalVariableWriteNode
        if self_assginment?(subnode)
          case subnode.rhs
          when TypeProf::Core::AST::OperatorNode
            "#{subnode.var}#{subnode.rhs.mid}=#{subnode.rhs.positional_args.map{rebuild_node(_1)}.join}"
          when TypeProf::Core::AST::OrNode
            "#{subnode.var}||=#{rebuild_node(subnode.rhs.e2)}"
          when TypeProf::Core::AST::AndNode
            "#{subnode.var}&&=#{rebuild_node(subnode.rhs.e2)}"
          end
        else
          "#{subnode.var}=#{rebuild_node(subnode.rhs)}"
        end
      when TypeProf::Core::AST::InstanceVariableReadNode
        subnode.var.to_s
      when TypeProf::Core::AST::InstanceVariableWriteNode
        if self_assginment?(subnode)
          case subnode.rhs
          when TypeProf::Core::AST::OperatorNode
            "#{subnode.var}#{subnode.rhs.mid}=#{subnode.rhs.positional_args.map{rebuild_node(_1)}.join}"
          when TypeProf::Core::AST::OrNode
            "#{subnode.var}||=#{rebuild_node(subnode.rhs.e2)}"
          when TypeProf::Core::AST::AndNode
            "#{subnode.var}&&=#{rebuild_node(subnode.rhs.e2)}"
          end
        else
          "#{subnode.var}=#{rebuild_node(subnode.rhs)}"
        end
      when TypeProf::Core::AST::ConstantReadNode
        "#{subnode.cbase.nil? ? '' : "#{rebuild_node(subnode.cbase)}::"}#{subnode.cname.to_s}"
      when TypeProf::Core::AST::ConstantWriteNode
        # TODO
        # joinするしかないのが微妙
        "#{subnode.static_cpath.join('::')}=#{rebuild_node(subnode.rhs)}"
      when TypeProf::Core::AST::StringNode
        subnode.lit.dump
      when TypeProf::Core::AST::IntegerNode
        subnode.lit.to_s
      when TypeProf::Core::AST::ArrayNode
        "[#{subnode.elems.map{rebuild_node(_1)}.join(',')}]"
      when TypeProf::Core::AST::SymbolNode
        ":#{subnode.lit}"
      when TypeProf::Core::AST::HashNode
        # TODO
        # 省略記法でかけるやつはかく
        "{" + subnode.keys.zip(subnode.vals).map do |key, val|
          "#{rebuild_node(key)}=>#{rebuild_node(val)}"
        end.join(',') + "}"
      when TypeProf::Core::AST::InterpolatedStringNode
        "\"" + subnode.parts.map do |part|
          case part
          when TypeProf::Core::AST::StringNode
            part.lit
          else
            "\#{#{rebuild_statement(part)}}"
          end
        end.join + "\""
      when TypeProf::Core::AST::InterpolatedSymbolNode
        ":\"" + subnode.parts.map do |part|
          case part
          when TypeProf::Core::AST::StringNode
            part.lit
          else
            "\#{#{rebuild_statement(part)}}"
          end
        end.join + "\""
      when TypeProf::Core::AST::IncludeMetaNode
        "include #{rebuild_node(subnode.args.first)}"
      when TypeProf::Core::AST::DummyNilNode
        ''
      when TypeProf::Core::AST::StatementsNode
        rebuild_statement(subnode)
      else
        raise MinifyError, "Unknown node: #{subnode.class}"
      end
    end

    def rebuild_statement(nodes)
      return if nodes.is_a?(TypeProf::Core::AST::DummyNilNode)
      return '' if nodes.nil?

      nodes.stmts.map do |subnode|
        rebuild_node(subnode)
      end.join("\n")
    end

    def middle_method?(method)
      %i[+ - * / ** % ^ > < <= >= <=> == ===].include?(method)
    end

    def need_quate?(node)
      %w[+ - / * % ^ & == === \\]
    end

    def self_assginment?(node)
      case node.rhs
      when TypeProf::Core::AST::OperatorNode
        node.var == node.rhs.recv.var
      when TypeProf::Core::AST::OrNode
        node.rhs.e1.var == node.var
      when TypeProf::Core::AST::AndNode
        node.rhs.e1.var == node.var
      else
        false
      end
    end

    def with_block_method?(node)
      !(node.block_body.nil? && node.block_pass.nil?)
    end

    def output(path = @path)
      File.write("./#{File.basename(path, '.rb')}.min.rb", @result)
    end
  end
end

class BaseMinify
  include Ruby::Minify
end

class SpecifyCache
  DEFAULT_CACHING_HASH = {
    :Kernel => {
      :p => 'p',
    },
    :Object => {
      :dup => 'dup',
    }
  }

  def initialize
    @cache = DEFAULT_CACHING_HASH
  end

  def set(key, value)
    @cache ||= {}
    @cache[key] = value
  end

  def get(key)
    @cache[key]
  end
end

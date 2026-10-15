# frozen_string_literal: true

module RedmineSvnAuthz
  # Builds authz text from the structured rule editor:
  #   groups[][name], groups[][members]               (members comma separated)
  #   rules[][section], rules[][principal], rules[][access]
  # +section+ is a section name such as /dirA, repo:/dirA or :glob:/src/*.
  # Rows with a blank name/section/principal are ignored, and rows keep their
  # order (it decides between overlapping wildcard rules). Aliases are kept
  # from the previously saved rules (they are not editable in the table).
  class RuleForm
    SectionRow = Struct.new(:header, :rules)
    RuleRow = Struct.new(:principal, :access)

    def initialize(params)
      @groups = rows(params[:groups])
      @rules = rows(params[:rules])
    end

    def to_authz(previous_policy)
      groups = {}
      @groups.each do |row|
        name = row[:name].to_s.strip
        next if name.empty?

        groups[name] = row[:members].to_s.split(',').map(&:strip).reject(&:empty?)
      end

      sections = []
      @rules.each do |row|
        header = row[:section].to_s.strip.delete_prefix('[').delete_suffix(']')
        principal = row[:principal].to_s.strip
        next if header.empty? || principal.empty?

        # "dirA" is accepted for "/dirA"; anything else is validated when the
        # generated text is parsed again
        header = "/#{header}" unless header.start_with?('/', ':') || header.include?(':/')
        sections << SectionRow.new(header, [RuleRow.new(principal, row[:access].to_s)])
      end

      aliases = previous_policy ? previous_policy.aliases : {}
      Serializer.new(groups, aliases, sections).dump
    end

    private

    # Accepts both arrays and the hash form Rails produces for indexed fields.
    def rows(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      list = value.is_a?(Hash) ? value.sort_by { |k, _| k.to_i }.map(&:last) : Array(value)
      list.map { |row| row.to_h.transform_keys(&:to_sym) }
    end
  end
end

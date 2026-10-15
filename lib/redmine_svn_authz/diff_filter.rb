# frozen_string_literal: true

module RedmineSvnAuthz
  # Removes the per-file sections of an `svn diff` output whose files are not
  # readable. Sections start with "Index: <path>" where <path> is relative to
  # the diff target.
  module DiffFilter
    HEADER = /\AIndex: (.+?)\r?\n?\z/

    # +lines+: diff output as an array of lines; +base+: browse path of the
    # diff target. The block receives a browse path and returns readability.
    def self.filter(lines, base)
      keep = true
      lines.select do |line|
        if (m = HEADER.match(line))
          keep = yield [base, m[1]].reject(&:empty?).join('/')
        end
        keep
      end
    end
  end
end

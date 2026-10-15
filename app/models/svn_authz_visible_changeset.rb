# frozen_string_literal: true

class SvnAuthzVisibleChangeset < ApplicationRecord
  belongs_to :visibility_set, :class_name => 'SvnAuthzVisibilitySet'
  belongs_to :changeset
end

# frozen_string_literal: true

class SvnAuthzVisibleChangeset < ActiveRecord::Base
  belongs_to :visibility_set, :class_name => 'SvnAuthzVisibilitySet'
  belongs_to :changeset
end

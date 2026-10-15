# frozen_string_literal: true

# Changesets visible under one set of effective authz rules (identified by
# UserRules#digest) of one repository. Used when the rules contain wildcards,
# which cannot be turned into a portable SQL condition on changes.path.
#
# Rows are added incrementally: each sync evaluates only the changes added
# since the previous one.
class SvnAuthzVisibilitySet < ApplicationRecord
  BATCH_SIZE = 5000
  # Sets not used for this long are deleted (rules changed since)
  UNUSED_FOR = 30.days

  belongs_to :repository
  has_many :visible_changesets, :class_name => 'SvnAuthzVisibleChangeset',
                                :foreign_key => :visibility_set_id

  def self.synced(repository, rules)
    set = find_or_create(repository.id, rules.digest)
    set.sync!(rules)
    set
  end

  def self.find_or_create(repository_id, digest)
    find_by(:repository_id => repository_id, :digest => digest) || begin
      purge(repository_id, where('updated_on < ?', UNUSED_FOR.ago))
      create!(:repository_id => repository_id, :digest => digest, :last_change_id => 0)
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(:repository_id => repository_id, :digest => digest)
  end

  # Deletes the sets of a repository (all of them by default).
  def self.purge(repository_id, scope = all)
    ids = scope.where(:repository_id => repository_id).pluck(:id)
    return if ids.empty?

    SvnAuthzVisibleChangeset.where(:visibility_set_id => ids).delete_all
    where(:id => ids).delete_all
  end

  # Records the visible changesets among the changes added since last sync.
  def sync!(rules)
    changes = Change.joins(:changeset).where(Changeset.table_name => { :repository_id => repository_id })
    max_id = changes.maximum(:id).to_i
    if max_id > last_change_id
      changes.where("#{Change.table_name}.id > ? AND #{Change.table_name}.id <= ?", last_change_id, max_id).
        in_batches(:of => BATCH_SIZE) do |batch|
          ids = batch.pluck("#{Change.table_name}.changeset_id", "#{Change.table_name}.path").
            select { |_, path| rules.readable?(path) }.map(&:first).uniq
          next if ids.empty?

          SvnAuthzVisibleChangeset.insert_all(ids.map { |cid| { :visibility_set_id => id, :changeset_id => cid } })
        end
      update_columns(:last_change_id => max_id, :updated_on => Time.now)
    elsif updated_on < 1.day.ago
      update_columns(:updated_on => Time.now)
    end
  end
end

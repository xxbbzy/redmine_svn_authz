# frozen_string_literal: true

class CreateSvnAuthzVisibilitySets < ActiveRecord::Migration[6.1]
  def change
    create_table :svn_authz_visibility_sets do |t|
      t.integer :repository_id, :null => false
      t.string :digest, :limit => 64, :null => false
      t.bigint :last_change_id, :null => false, :default => 0
      t.datetime :updated_on, :null => false
    end
    add_index :svn_authz_visibility_sets, [:repository_id, :digest], :unique => true

    create_table :svn_authz_visible_changesets do |t|
      t.integer :visibility_set_id, :null => false
      t.integer :changeset_id, :null => false
    end
    add_index :svn_authz_visible_changesets, [:visibility_set_id, :changeset_id],
              :unique => true, :name => 'index_svn_authz_visible_on_set_and_changeset'
  end
end

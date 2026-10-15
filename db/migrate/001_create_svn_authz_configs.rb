# frozen_string_literal: true

class CreateSvnAuthzConfigs < ActiveRecord::Migration[6.1]
  def change
    create_table :svn_authz_configs do |t|
      t.integer :repository_id, :null => false
      t.boolean :enabled, :null => false, :default => false
      t.string :source, :null => false, :default => 'managed'
      t.string :authz_file_path
      t.text :authz_content
      t.string :authz_repo_name
      t.string :path_prefix_override
      t.string :export_path
      t.timestamps :null => false
    end
    add_index :svn_authz_configs, :repository_id, :unique => true
  end
end

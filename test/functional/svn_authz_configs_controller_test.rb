# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class SvnAuthzConfigsControllerTest < Redmine::ControllerTest
  include SvnAuthzTestHelper

  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules, :repositories

  def setup
    User.current = nil
    @repository = create_authz_repository
    Role.find(1).add_permission! :manage_svn_authz
    @request.session[:user_id] = 2
  end

  def test_requires_permission
    @request.session[:user_id] = 3
    get :edit, :params => { :repository_id => @repository.id }
    assert_response 403
  end

  def test_edit_with_preview
    get :edit, :params => { :repository_id => @repository.id, :preview_login => 'jsmith',
                            :preview_path => '/trunk/dirA/secret/x' }
    assert_response :success
    assert_select 'textarea#svn_authz_config_authz_content'
    assert_select 'code', :text => '[/trunk/dirA/secret]'
    assert_select 'code', :text => '[/trunk/dirB]', :count => 0
    assert_select 'p', :text => %r{/trunk/dirA/secret/x:\s*none}
  end

  def test_update_raw_rejects_invalid_rules
    patch :update, :params => {
      :repository_id => @repository.id, :editor => 'raw',
      :svn_authz_config => { :authz_content => "[/x]\n@missing = r\n" }
    }
    assert_response :success
    assert_select '#errorExplanation', :text => /undefined group '@missing'/
  end

  def test_update_from_rule_table
    patch :update, :params => {
      :repository_id => @repository.id, :editor => 'rules',
      :svn_authz_config => { :enabled => '1', :source => 'managed' },
      :groups => { '0' => { :name => 'team', :members => 'jsmith, dlopper' } },
      :rules => {
        '0' => { :section => '/trunk/dirB', :principal => '@team', :access => 'r' },
        '1' => { :section => '', :principal => '', :access => 'r' }
      }
    }
    assert_redirected_to "/repositories/#{@repository.id}/svn_authz"
    text = @repository.svn_authz_config.reload.authz_content
    assert_includes text, "team = jsmith, dlopper"
    assert_includes text, "[/trunk/dirB]\n@team = r"
  end

  def test_file_source_requires_an_allowed_directory
    patch :update, :params => {
      :repository_id => @repository.id, :editor => 'raw',
      :svn_authz_config => { :source => 'file', :authz_file_path => '/etc/passwd' }
    }
    assert_response :success
    assert_select '#errorExplanation', :text => /allowed directory/
  end

  def test_file_source_and_export
    dir = Dir.mktmpdir
    with_settings :plugin_redmine_svn_authz => { 'allowed_directories' => dir } do
      export = File.join(dir, 'authz')
      patch :update, :params => {
        :repository_id => @repository.id, :editor => 'raw',
        :svn_authz_config => { :authz_content => AUTHZ, :export_path => export }
      }
      assert_equal AUTHZ, File.read(export)

      patch :update, :params => {
        :repository_id => @repository.id,
        :svn_authz_config => { :source => 'file', :authz_file_path => export }
      }
      assert @repository.svn_authz_config.reload.file_source?
      get :download, :params => { :repository_id => @repository.id }
      assert_equal AUTHZ, response.body
    end
  ensure
    FileUtils.rm_rf(dir)
  end
end

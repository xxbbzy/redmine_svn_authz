# frozen_string_literal: true

class SvnAuthzConfigsController < ApplicationController
  menu_item :settings
  helper :repositories

  before_action :find_repository, :authorize, :find_config

  BLANK_RULE_ROWS = 3

  def edit
    @authz_text = current_authz_text
    load_preview
  end

  def update
    @config.attributes = config_params
    if params[:editor] == 'rules' && !@config.file_source?
      @config.authz_content = RedmineSvnAuthz::RuleForm.new(params).to_authz(@config.parsed_policy)
    end
    if @config.save && @config.export!
      flash[:notice] = l(:notice_successful_update)
      redirect_to edit_repository_svn_authz_path(@repository)
    else
      @authz_text = @config.authz_content
      render :edit
    end
  end

  # Copies an authz file into the managed rules; nothing is saved until the
  # user submits the form.
  def import
    path = params[:import_path].presence || @config.authz_file_path
    if RedmineSvnAuthz.path_allowed?(path) && File.file?(path)
      @config.source = 'managed'
      @config.authz_content = File.read(path)
      @authz_text = @config.authz_content
      flash.now[:notice] = l(:notice_svn_authz_imported, :path => path)
    else
      @config.errors.add(:authz_file_path, :svn_authz_path_not_allowed)
    end
    render :edit
  end

  def download
    send_data @config.authz_text, :type => 'text/plain',
              :filename => "authz-#{@repository.identifier.presence || @repository.id}"
  rescue SystemCallError => e
    render_error :message => e.message, :status => 404
  end

  private

  def find_repository
    @repository = Repository.find(params[:repository_id])
    @project = @repository.project
    render_404 unless @repository.is_a?(Repository::Subversion)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def find_config
    @config = @repository.svn_authz_config || @repository.build_svn_authz_config
  end

  def config_params
    params.fetch(:svn_authz_config, {}).permit(
      :enabled, :source, :authz_file_path, :authz_content,
      :authz_repo_name, :path_prefix_override, :export_path
    )
  end

  def current_authz_text
    @config.authz_text
  rescue SystemCallError
    nil
  end

  # "Preview as user": effective decisions for one login (blank = anonymous).
  def load_preview
    return unless params.key?(:preview_login)

    @preview_login = params[:preview_login].to_s.strip
    @preview_path = params[:preview_path].to_s.strip.presence
    @preview_user = User.find_by_login(@preview_login) if @preview_login.present?
    policy = @config.parsed_policy
    return unless policy&.valid?

    @preview_rules = policy.user_rules(@preview_login.presence, :repo => @config.repo_name)
  end
end

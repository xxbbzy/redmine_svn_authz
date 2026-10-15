# frozen_string_literal: true

module RedmineSvnAuthz
  class Hooks < Redmine::Hook::ViewListener
    # "Directory permissions" link on the repository browser
    def view_repositories_show_contextual(context = {})
      repository = context[:repository]
      return '' unless repository.is_a?(Repository::Subversion) &&
                       User.current.allowed_to?(:manage_svn_authz, context[:project])

      link_to(l(:label_svn_authz), edit_repository_svn_authz_path(repository), :class => 'icon icon-lock')
    end
  end
end

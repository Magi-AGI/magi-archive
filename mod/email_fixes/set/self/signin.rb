# frozen_string_literal: true

# Allow *signin's identifier field to accept either account email or user/card name.
def account_for login_identifier
  account_by_email(login_identifier) || account_by_login_name(login_identifier)
end

def authenticate_and_signin login_identifier, pword
  return unless (account = account_for(login_identifier))
  return unless account.active?
  return unless Auth.not_required? || Auth.password_valid?(account, pword.strip)

  Auth.signin account.left_id
end

def account_by_email login_identifier
  Auth.find_account_by_email login_identifier.to_s
end

def account_by_login_name login_identifier
  login_identifier = login_identifier.to_s.strip
  return if login_identifier.blank?

  Auth.as_bot do
    user = login_user_card(login_identifier)
    next unless user

    account = user.fetch(:account)
    account if account&.real?
  end
end

def login_user_card login_identifier
  user = Card[login_identifier]
  return user if login_user_card?(user)

  Card.where("lower(name) = ?", login_identifier.downcase)
      .where(type_id: login_user_type_ids)
      .first
end

def login_user_card? card
  card&.real? && ["User", "Sign up"].include?(card.type_name)
end

def login_user_type_ids
  @login_user_type_ids ||= ["User", "Sign up"].filter_map { |type_name| Card[type_name]&.id }
end

format :html do
  def signin_field name
    nest_name = "".to_name.field(name)
    title = name == :email ? "Username or email" : name.to_s
    [nest_name, { title: title, view: "titled",
                  nest_name: nest_name, skip_perms: true }]
  end
end

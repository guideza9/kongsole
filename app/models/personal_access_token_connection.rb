# Join row between a PersonalAccessToken and one KongConnection it may
# access. The interesting constraint (only credential_mode: "stored"
# connections are attachable) lives on PersonalAccessToken.issue! rather
# than here, since it needs to raise a clear error at issuance time, not a
# generic validation failure on the join.
class PersonalAccessTokenConnection < ApplicationRecord
  belongs_to :personal_access_token
  belongs_to :kong_connection
end

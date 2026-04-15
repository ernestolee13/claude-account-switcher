#!/bin/bash
# 현재 Keychain의 Claude 크리덴셜을 지정된 계정 번호로 백업
# Usage: bash claude-save-accounts.sh 1   (현재 로그인된 계정을 account1로 저장)
#        bash claude-save-accounts.sh 2   (현재 로그인된 계정을 account2로 저장)

ACCT="${1:?Usage: $0 <1|2>}"
KEYCHAIN_SERVICE="Claude Code-credentials"
KEYCHAIN_ACCOUNT="${USER}"
CRED_DIR="$HOME/.claude"

CRED=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null)
if [ -z "$CRED" ]; then
  echo "ERROR: No Claude credentials in Keychain. Run 'claude' and login first."
  exit 1
fi

echo "$CRED" > "$CRED_DIR/credentials-account${ACCT}.json"
EMAIL=$(echo "$CRED" | jq -r '.claudeAiOauth.subscriptionType // "unknown"' 2>/dev/null)
echo "Saved current credentials as account${ACCT} (subscription: $EMAIL)"
echo "File: $CRED_DIR/credentials-account${ACCT}.json"

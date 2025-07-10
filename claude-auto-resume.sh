#!/bin/bash

# Auto-resume script for Claude CLI tasks
# Depends only on standard shell commands and claude CLI

# Default prompt to use when resuming
DEFAULT_PROMPT="continue"
# Default is to start new session (no -c flag)
USE_CONTINUE_FLAG=false
# Repeat execution continuously
REPEAT_MODE=false

# Function to show help
show_help() {
    cat << EOF
Usage: claude-auto-resume [OPTIONS] [PROMPT]

Automatically resume Claude CLI tasks after usage limits are lifted.

OPTIONS:
    -p, --prompt PROMPT    Custom prompt to use when resuming (default: "continue")
    -c, --continue        Continue previous conversation (add -c flag to claude command)
    -r, --repeat         Repeat execution continuously (waits on limits)
    -h, --help           Show this help message

ARGUMENTS:
    PROMPT               Custom prompt to use when resuming (alternative to -p)

EXAMPLES:
    claude-auto-resume                                    # Start new session with "continue"
    claude-auto-resume "implement user authentication"    # Start new session with custom prompt
    claude-auto-resume -p "write unit tests"             # Start new session with -p flag
    claude-auto-resume -c "please continue the task"     # Continue previous conversation
    claude-auto-resume -c -p "resume where we left off"  # Continue previous conversation with -p flag
    claude-auto-resume -r -p "process all files"         # Repeat continuously

SECURITY WARNING:
    ⚠️  This script uses --dangerously-skip-permissions which bypasses all safety prompts.
    ⚠️  Claude will execute commands automatically without asking for permission.
    ⚠️  Use only in trusted environments with carefully crafted prompts.

NOTES:
    - By default, starts a new session (uses claude without -c)
    - Use -c/--continue to continue the previous conversation
    - This matches the natural expectation: new session by default, explicit flag to continue

EOF
}

# Parse command line arguments
CUSTOM_PROMPT="$DEFAULT_PROMPT"

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prompt)
            CUSTOM_PROMPT="$2"
            shift 2
            ;;
        -c|--continue)
            USE_CONTINUE_FLAG=true
            shift
            ;;
        -r|--repeat)
            REPEAT_MODE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            # If no flag specified, treat as prompt argument
            CUSTOM_PROMPT="$1"
            shift
            ;;
    esac
done

# Function to execute claude with the custom prompt
execute_claude_with_prompt() {
  local max_retries=6
  local retry_count=0
  
  while [ $retry_count -lt $max_retries ]; do
    if [ "$USE_CONTINUE_FLAG" = true ]; then
      echo "Automatically continuing previous Claude conversation with prompt: '$CUSTOM_PROMPT'"
      CLAUDE_OUTPUT=$(claude -c --dangerously-skip-permissions -p "$CUSTOM_PROMPT" 2>&1)
    else
      echo "Automatically starting new Claude session with prompt: '$CUSTOM_PROMPT'"
      CLAUDE_OUTPUT=$(claude --dangerously-skip-permissions -p "$CUSTOM_PROMPT" 2>&1)
    fi
    RET_CODE=$?
    
    # First check for usage limit message
    LIMIT_MSG=$(echo "$CLAUDE_OUTPUT" | grep "Claude AI usage limit reached")
    if [ -n "$LIMIT_MSG" ]; then
      # Extract timestamp from usage limit message
      RESUME_TIMESTAMP=$(echo "$CLAUDE_OUTPUT" | awk -F'|' '{print $2}' | tr -d '\r\n[:space:]')
      if ! [[ "$RESUME_TIMESTAMP" =~ ^[0-9]+$ ]] || [ "$RESUME_TIMESTAMP" -le 0 ]; then
        echo "[ERROR] Failed to extract a valid resume timestamp from CLI output during execution."
        echo "Output was: $CLAUDE_OUTPUT"
        return 1
      fi
      
      echo "[INFO] Usage limit detected during execution."
      wait_for_limit "$RESUME_TIMESTAMP"
      
      # After waiting, retry the command
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        continue
      else
        echo "[ERROR] Usage limit persists after $max_retries attempts."
        return 1
      fi
    fi
    
    # Check for various API errors and set appropriate wait times
    local wait_seconds=0
    local error_type=""
    
    if echo "$CLAUDE_OUTPUT" | grep -q "API Error: 400" || echo "$CLAUDE_OUTPUT" | grep -q "invalid_request_error"; then
      error_type="400 Bad Request (invalid_request_error)"
      wait_seconds=60  # 1 minute for bad requests
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 401" || echo "$CLAUDE_OUTPUT" | grep -q "authentication_error"; then
      error_type="401 Authentication Error"
      # Authentication errors shouldn't be retried with wait
      echo "[ERROR] Authentication error detected. Please check your API key."
      echo "$CLAUDE_OUTPUT"
      return 1
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 403" || echo "$CLAUDE_OUTPUT" | grep -q "permission_error"; then
      error_type="403 Permission Error"
      # Permission errors shouldn't be retried
      echo "[ERROR] Permission error detected. Your API key lacks necessary permissions."
      echo "$CLAUDE_OUTPUT"
      return 1
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 404" || echo "$CLAUDE_OUTPUT" | grep -q "not_found_error"; then
      error_type="404 Not Found Error"
      wait_seconds=60  # 1 minute
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 413" || echo "$CLAUDE_OUTPUT" | grep -q "request_too_large"; then
      error_type="413 Request Too Large"
      # Request too large shouldn't be retried
      echo "[ERROR] Request too large. Please reduce the request size."
      echo "$CLAUDE_OUTPUT"
      return 1
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 429" || echo "$CLAUDE_OUTPUT" | grep -q "rate_limit_error"; then
      error_type="429 Rate Limit Error"
      wait_seconds=300  # 5 minutes for rate limits
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 500" || echo "$CLAUDE_OUTPUT" | grep -q "Internal server error" || echo "$CLAUDE_OUTPUT" | grep -q "api_error"; then
      error_type="500 Internal Server Error"
      wait_seconds=1200  # 20 minutes for server errors
    elif echo "$CLAUDE_OUTPUT" | grep -q "API Error: 529" || echo "$CLAUDE_OUTPUT" | grep -q "overloaded_error"; then
      error_type="529 Overloaded Error"
      wait_seconds=600  # 10 minutes for overload
    fi
    
    # If an error was detected that should be retried
    if [ $wait_seconds -gt 0 ]; then
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        echo "[WARNING] API Error detected ($error_type). Waiting before retry attempt $retry_count/$max_retries..."
        echo "Error details: $CLAUDE_OUTPUT"
        
        # Wait with countdown
        while [ $wait_seconds -gt 0 ]; do
          printf "\rRetrying in %02d:%02d..." $((wait_seconds/60)) $((wait_seconds%60))
          sleep 1
          wait_seconds=$((wait_seconds - 1))
        done
        printf "\rRetrying now...                    \n"
        continue
      else
        echo "[ERROR] API Error persists after $max_retries attempts. Output:"
        echo "$CLAUDE_OUTPUT"
        return 1
      fi
    elif [ $RET_CODE -ne 0 ]; then
      echo "[ERROR] Claude CLI failed. Output:"
      echo "$CLAUDE_OUTPUT"
      return 1
    else
      # Success
      echo "Task completed."
      printf "CLAUDE_OUTPUT: \n"
      echo "$CLAUDE_OUTPUT"
      return 0
    fi
  done
  
  # Should not reach here, but just in case
  return 1
}

# Function to wait for limit to be lifted
wait_for_limit() {
  local RESUME_TIMESTAMP=$1
  local NOW_TIMESTAMP=$(date +%s)
  local WAIT_SECONDS=$((RESUME_TIMESTAMP - NOW_TIMESTAMP))
  
  if [ $WAIT_SECONDS -le 0 ]; then
    echo "Resume time has arrived. Retrying now."
    return
  fi
  
  # Format time compatible with Linux and macOS
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    RESUME_TIME_FMT=$(date -d "@$RESUME_TIMESTAMP" "+%Y-%m-%d %H:%M:%S")
  else
    # BSD date (macOS)
    RESUME_TIME_FMT=$(date -r $RESUME_TIMESTAMP "+%Y-%m-%d %H:%M:%S")
  fi
  
  if [ -z "$RESUME_TIME_FMT" ] || [[ "$RESUME_TIME_FMT" == *"?"* ]]; then
    echo "Claude usage limit detected. Waiting for $WAIT_SECONDS seconds (failed to format resume time, raw timestamp: $RESUME_TIMESTAMP)..."
  else
    echo "Claude usage limit detected. Waiting until $RESUME_TIME_FMT..."
  fi
  
  # Live countdown
  while [ $WAIT_SECONDS -gt 0 ]; do
    printf "\rResuming in %02d:%02d:%02d..." $((WAIT_SECONDS/3600)) $(( (WAIT_SECONDS%3600)/60 )) $((WAIT_SECONDS%60))
    sleep 1
    NOW_TIMESTAMP=$(date +%s)
    WAIT_SECONDS=$((RESUME_TIMESTAMP - NOW_TIMESTAMP))
  done
  printf "\rResume time has arrived. Retrying now.           \n"
  sleep 10
}

# Main execution loop
while true; do
  # Execute the actual command directly
  execute_claude_with_prompt
  EXEC_RESULT=$?
  
  if [ $EXEC_RESULT -ne 0 ]; then
    exit 4
  fi
  
  # Check if should repeat
  if [ "$REPEAT_MODE" = false ]; then
    break
  fi
  
  # Optional: Add small delay between iterations to avoid hammering the API
  echo "Waiting 5 seconds before next iteration..."
  sleep 5
done

exit 0

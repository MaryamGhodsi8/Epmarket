#!/bin/bash

TOKEN_FILE="/tmp/epmarket.token"
TOKEN_TIME_FILE="/tmp/epmarket.token_time"

LAST_API_REQUEST=0
LAST_REQUEST_FILE="/tmp/epmarket.last_request"

BASE_DIR="/opt/data/epmarket"
DB_DIR="$BASE_DIR/db"
LOG_DIR="$BASE_DIR/logs"

SYMBOLS_FILE="$DB_DIR/symbols.txt"
WALLET_FILE="$DB_DIR/wallet.txt"
ORDERS_FILE="$DB_DIR/orders.txt"

TRADES_LOG="$LOG_DIR/trades.log"
MISSED_TRADES_LOG="$LOG_DIR/missed_trades.log"
ERROR_LOG="$LOG_DIR/error.log"

LOCK_FILE="/tmp/epmarket.lock"
API_LOCK_FILE="/tmp/epmarket_api.lock"

STOP_LOSS_PERCENT=10

show_help() {
    echo "Emperor Penguin Market - epmarket"
    echo
    echo "Usage: epmarket [OPTION]"
    echo
    echo "Options:"
    echo "  -i              Open interactive menu"
    echo "  -h              Show help"
    echo "  -l              List monitored symbols"
    echo "  -u              Update prices and process orders"
    echo "  --wallet        Show wallet"
    echo "  --statement     Show trading statement"
    echo "  --buy SYMBOL AMOUNT_IRR    Buy cryptocurrency manually"
    echo "  --sell SYMBOL              Sell all holdings of a cryptocurrency"
    echo "  --order SYMBOL MIN_USD MAX_USD AMOUNT_IRR "
    echo "                       Create a conditional buy order"
}

log_error() {
    local http_code="$1"
    local endpoint="$2"
    local attempt="$3"
    local total_attempts="$4" 
    local message="$5"
    local retry_delay="${6:-}"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [HTTP $http_code] $endpoint | Attempt $attempt/$total_attempts | $message" \
        >> "$LOG_DIR/error.log"
    
    if [[ -n "$retry_delay" ]]; then
        echo "Retrying in ${retry_delay}s..." >> "$LOG_DIR/error.log"
    fi

}

api_curl() {
    local response curl_status
    local now last_request elapsed remaining

    # Acquire shared API lock
    exec 201>"$API_LOCK_FILE"

    if ! flock -x 201; then
    	echo "Error: Unable to acquire API lock." >&2
    	exec 201>&-
    	return 1
    fi

    # Check the time of the previous request
    now=$(date +%s%N)
    last_request=0

    if [[ -f "$LAST_REQUEST_FILE" ]]; then
        read -r last_request < "$LAST_REQUEST_FILE"
    fi

    if [[ "$last_request" =~ ^[0-9]+$ ]] && (( last_request > 0 )); then
        elapsed=$((now - last_request))
        remaining=$((3000000000 - elapsed))

        if (( remaining > 0 )); then
            sleep "$(awk -v ns="$remaining" 'BEGIN { printf "%.9f", ns / 1000000000 }')"
        fi
    fi

    # Save request start time
    now=$(date +%s%N)
    printf '%s\n' "$now" > "$LAST_REQUEST_FILE"
    
    # Execute curl while holding the lock
    if response=$(curl "$@"); then
        curl_status=0
    else
        curl_status=$?
    fi
    
 # Release lock after curl finishes
    flock -u 201
    exec 201>&-

    printf '%s' "$response"
    return "$curl_status"
}

get_token() {
    local token=""
    local now
    local saved_at
    local response
    local http_code
    local body
    local curl_status
    local attempt=1
    local retry_delay

    now=$(date +%s)

    # Check cached token
    if [[ -f "$TOKEN_FILE" && -f "$TOKEN_TIME_FILE" ]]; then
        token=$(cat "$TOKEN_FILE")
        saved_at=$(cat "$TOKEN_TIME_FILE")

        if [[ "$saved_at" =~ ^[0-9]+$ ]] &&
           (( now >= saved_at && now - saved_at < 600 )) &&
           [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    fi

    # Login with retry
    while (( attempt <= 3 )); do

        if response=$(api_curl -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -w "\n%{http_code}" \
            -X POST \
            -H "User-Agent: Penguin-Client" \
            "https://epmarket.partcollege.ir/api/login"); then
            curl_status=0
        else
            curl_status=$?
        fi

        if (( curl_status != 0 )); then
    	    retry_delay=$((attempt * 2))

    	    if (( attempt < 3 )); then
        	log_error "000" "/api/login" "$attempt" 3 "Curl error: $curl_status" "$retry_delay"
    	    else
        	log_error "000" "/api/login" "$attempt" 3 "Curl error: $curl_status"
    	    fi

        else
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"

            if [[ "$http_code" == "200" ]]; then
                token=$(echo "$body" | jq -r '.token // empty')

                if [[ -n "$token" ]]; then
                    now=$(date +%s)

                    echo "$token" > "$TOKEN_FILE"
                    echo "$now" > "$TOKEN_TIME_FILE"

                    chmod 600 "$TOKEN_FILE" "$TOKEN_TIME_FILE"

                    echo "$token"
                    return 0
                fi

                echo "Error: Login response does not contain a valid token." >&2
                return 1

            elif [[ "$http_code" == "429" ]]; then
    		retry_delay=$((attempt * 4))

    		if (( attempt < 3 )); then
        	    log_error "$http_code" "/api/login" "$attempt" 3 "Rate limit exceeded" "$retry_delay"
    		else
        	    log_error "$http_code" "/api/login" "$attempt" 3 "Rate limit exceeded"
    		fi

            elif [[ "$http_code" == "500" ]]; then
    		retry_delay=$((attempt * 2))

    		if (( attempt < 3 )); then
        	    log_error "$http_code" "/api/login" "$attempt" 3 "Internal Server Error" "$retry_delay"
    		else
        	    log_error "$http_code" "/api/login" "$attempt" 3 "Internal Server Error"
    		fi

            else
                echo "Error: Login failed with HTTP $http_code." >&2
                return 1
            fi
        fi

        ((attempt++))

        if (( attempt <= 3 )); then
            sleep "$retry_delay"
        fi
    done

    echo "Error: Unable to obtain API token after 3 attempts." >&2
    return 1
}

wait_for_rate_limit() {
    exec 201>"$API_LOCK_FILE"
    flock -x 201

    local last_request=0
    local now
    local elapsed
    local remaining

    if [[ -f "$LAST_REQUEST_FILE" ]]; then
        last_request=$(cat "$LAST_REQUEST_FILE")
    fi
    
    now=$(date +%s%N)

    if [[ "$last_request" =~ ^[0-9]+$ ]] && (( last_request > 0 )); then
    	 elapsed=$((now - last_request))
   	 remaining=$((2000000000 - elapsed))

	 if (( remaining > 0 )); then
	     sleep "$(awk -v ns="$remaining" \
		'BEGIN { printf "%.3f", ns / 1000000000 }')"
    	 fi
    fi
    
    date +%s%N > "$LAST_REQUEST_FILE"
   
    flock -u 201
    exec 201>&-
}

api_request() {
    local url="$1"
    local token="$2"
    local endpoint="${url#https://epmarket.partcollege.ir}"
    local attempt=1
    local response
    local http_code
    local body
    local curl_status
    local retry_delay

    while (( attempt <= 3 )); do

        if response=$(api_curl -sS -L \
            --connect-timeout 5 \
            --max-time 15 \
            -w "\n%{http_code}" \
            -H "User-Agent: Penguin-Client" \
            -H "X-Token: $token" \
            "$url"); then
            curl_status=0
        else
            curl_status=$?
        fi

        http_code="${response##*$'\n'}"
        body="${response%$'\n'*}"

        # Handle curl/network errors
        if (( curl_status != 0 )); then
            log_error "000" "$endpoint" "$attempt" 3 "Curl error: $curl_status"
            printf '000|%s\n' "$body"
            return 0
        fi

        # Handle rate limit errors
	if [[ "$http_code" == "429" ]]; then
    	    retry_delay=$((attempt * 4))

    	if (( attempt < 3 )); then
            log_error "$http_code" "$endpoint" "$attempt" 3 "Rate limit exceeded" "$retry_delay"
    	else
            log_error "$http_code" "$endpoint" "$attempt" 3 "Rate limit exceeded"
    	fi

	# Handle server errors
	elif [[ "$http_code" == "500" ]]; then
     	     retry_delay=$((attempt * 2))

    	if (( attempt < 3 )); then
            log_error "$http_code" "$endpoint" "$attempt" 3 "Internal Server Error" "$retry_delay"
    	else
            log_error "$http_code" "$endpoint" "$attempt" 3 "Internal Server Error"
    	fi

        else
            if [[ "$http_code" != "200" ]]; then
                log_error "$http_code" "$endpoint" "$attempt" 3  "API request failed"
            fi

            printf '%s|%s\n' "$http_code" "$body"
            return 0
        fi

        ((attempt++))

        if (( attempt <= 3 )); then
            sleep "$retry_delay"
        fi
    done

    # Return the actual final HTTP status and response body
    printf '%s|%s\n' "$http_code" "$body"
}

api_get() {
    local url="$1"
    local token
    local response
    local http_code

    token=$(get_token) || return 1

    response=$(api_request "$url" "$token")
    http_code="${response%%|*}"

    if [[ "$http_code" == "401" ]]; then
        rm -f "$TOKEN_FILE" "$TOKEN_TIME_FILE"

        token=$(get_token) || return 1
        response=$(api_request "$url" "$token")
    fi

    printf '%s\n' "$response"
}

check_api_symbol() {
    local symbol="$1"
    local response

    response=$(api_get \
        "https://epmarket.partcollege.ir/api/crypto/$symbol") || return 1

    echo "${response%%|*}"
}


update_prices() {
    local response http_code body dollar_rate
    local symbol price_usd price_irr name change trend timestamp date
    local -a updated_symbols=()

    echo "Getting dollar rate..."

    response=$(api_get "https://epmarket.partcollege.ir/api/dollar") || {
        echo "Error: Could not get dollar rate."
        return 1
    }

    http_code="${response%%|*}"
    body="${response#*|}"

    if [[ "$http_code" != "200" ]]; then
        echo "Error: Dollar API returned HTTP $http_code"
        return 1
    fi

    dollar_rate=$(jq -r '.rate' <<< "$body")

    if [[ ! "$dollar_rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "Error: Invalid dollar rate."
        return 1
    fi

    while IFS= read -r symbol; do
        [[ -z "$symbol" ]] && continue

        echo "Updating $symbol..."

        response=$(api_get \
            "https://epmarket.partcollege.ir/api/crypto/$symbol") || {
            echo "Error: Could not get $symbol price."
            continue
        }

        http_code="${response%%|*}"
        body="${response#*|}"

        if [[ "$http_code" != "200" ]]; then
            echo "Error: $symbol API returned HTTP $http_code"
            continue
        fi

        name=$(jq -r '.name' <<< "$body")
        price_usd=$(jq -r '.price_usd' <<< "$body")
        change=$(jq -r '.change_24h' <<< "$body")
        trend=$(jq -r '.trend' <<< "$body")
        timestamp=$(jq -r '.timestamp' <<< "$body")

        if [[ ! "$price_usd" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "Error: Invalid price for $symbol."
            continue
        fi

        price_irr=$(awk -v p="$price_usd" -v r="$dollar_rate" \
            'BEGIN { printf "%.0f", p * r }')

        date=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S") || continue

        printf "%s: %s/%s - %s USD - %s IRR - %s - %s\n" \
            "$date" "$symbol" "$name" "$price_usd" \
            "$price_irr" "$change" "$trend" \
            >> "$DB_DIR/-$symbol.txt" || continue

        updated_symbols+=("$symbol")

    done < "$SYMBOLS_FILE"

    process_orders
    process_stop_losses "${updated_symbols[@]}"

    echo "Price update completed."
}


list_prices() {
    local symbol
    local history_file
    local last_line

    printf "\n%-8s %-20s %-12s %-15s %-12s\n" \
        "SYMBOL" "LAST UPDATE" "USD" "IRR" "TREND"

    printf '%s\n' "--------------------------------------------------------------------------"

    while IFS= read -r symbol; do
        [[ -z "$symbol" ]] && continue

        history_file="$DB_DIR/-$symbol.txt"

        if [[ ! -s "$history_file" ]]; then
            printf "%-8s %-20s %-12s %-15s %-12s\n" \
                "$symbol" "No data" "-" "-" "-"
            continue
        fi

        last_line=$(tail -n 1 "$history_file")

        local date
        local price_usd
        local price_irr
        local trend

        date=$(awk -F': ' '{print $1}' <<< "$last_line")
        price_usd=$(awk '{print $5}' <<< "$last_line")
        price_irr=$(awk '{print $8}' <<< "$last_line")
        trend=$(awk '{print $NF}' <<< "$last_line")

        printf "%-8s %-20s %-12s %-15s %-12s\n" \
            "$symbol" "$date" "$price_usd" "$price_irr" "$trend"

    done < "$SYMBOLS_FILE"

    echo
}



show_wallet() {
    local symbol quantity avg_price
    local history_file last_line current_price
    local current_value cost_basis profit_loss
    local cash=0 total_assets=0 total_cost=0
    local invalid=0
    local profit_percent total_profit_percent
	local realized_pl=0

    if [[ ! -f "$WALLET_FILE" || ! -s "$WALLET_FILE" ]]; then
        echo "Error: Wallet file is missing or empty."
        return 1
    fi

    if [[ ! -f "$SYMBOLS_FILE" ]]; then
        echo "Error: Symbols file not found."
        return 1
    fi

    printf "\n%-8s %-14s %-16s %-16s %-16s %-12s\n" \
        "SYMBOL" "QUANTITY" "AVG BUY(IRR)" "VALUE(IRR)" "P/L(IRR)" "P/L(%)"

    printf '%s\n' "--------------------------------------------------------------------------------"

    while IFS=: read -r symbol quantity avg_price; do
        symbol=$(xargs <<< "$symbol")
        quantity=$(xargs <<< "$quantity")
        avg_price=$(xargs <<< "$avg_price")

        [[ -z "$symbol" ]] && continue

        if [[ "$symbol" == "CASH_IRR" ]]; then
            if [[ "$quantity" =~ ^[0-9]+$ ]]; then
                cash="$quantity"
            else
                echo "Error: Invalid cash balance."
                invalid=1
            fi
            continue
        fi

        if [[ ! "$quantity" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   	   [[ ! "$avg_price" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
   	   ! awk -v q="$quantity" -v p="$avg_price" \
       		'BEGIN {exit (q > 0 && p > 0) ? 0 : 1}'; then
            echo "Error: Invalid wallet entry for $symbol."
            invalid=1
            continue
        fi

        if ! grep -Fxq "$symbol" "$SYMBOLS_FILE"; then
            echo "Error: Unknown symbol $symbol."
            invalid=1
            continue
        fi

        history_file="$DB_DIR/-$symbol.txt"

        if [[ ! -s "$history_file" ]]; then
            echo "Warning: No price history for $symbol."
            invalid=1
            continue
        fi

        last_line=$(tail -n 1 "$history_file")
        current_price=$(awk '{print $8}' <<< "$last_line")

        if [[ ! "$current_price" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "Error: Invalid current price for $symbol."
            invalid=1
            continue
        fi

        current_value=$(awk -v q="$quantity" -v p="$current_price" \
            'BEGIN {printf "%.0f", q*p}')

        cost_basis=$(awk -v q="$quantity" -v p="$avg_price" \
            'BEGIN {printf "%.0f", q*p}')

        profit_loss=$((current_value - cost_basis))
	profit_percent=$(awk -v pl="$profit_loss" -v cost="$cost_basis" \
    	     'BEGIN {if (cost > 0) printf "%.2f", (pl/cost)*100; else print "0.00"}')
        
	total_assets=$((total_assets + current_value))
        total_cost=$((total_cost + cost_basis))

        printf "%-8s %-14s %-16s %-16s %-16s %-12s\n" \
            "$symbol" "$quantity" "$avg_price" "$current_value" "$profit_loss" "$profit_percent"

    done < "$WALLET_FILE"

    local total_value=$((cash + total_assets))
    local total_profit=$((total_assets - total_cost))
    total_profit_percent=$(awk -v pl="$total_profit" -v cost="$total_cost" \
    	'BEGIN {if (cost > 0) printf "%.2f", (pl/cost)*100; else print "0.00"}')
    if [[ -f "$TRADES_LOG" ]]; then
        realized_pl=$(awk -F'|' '
            $1 ~ /\[SELL\]|\[STOP_LOSS\]/ {
                gsub(/^[ \t]+|[ \t]+$/, "", $NF)
                if ($NF ~ /^-?[0-9]+([.][0-9]+)?$/)
                    total += $NF
            }
            END {printf "%.0f", total}
        ' "$TRADES_LOG")
    fi
	echo
    echo "Cash Balance:       $cash IRR"
    echo "Assets Value:       $total_assets IRR"
    echo "Total Wallet Value: $total_value IRR"
    echo "Assets P/L:         $total_profit IRR"
    echo "Total Assets P/L:   ${total_profit_percent}%"
    if (( realized_pl > 0 )); then
        printf "Realized P/L:       \033[32m+%s IRR\033[0m\n" "$realized_pl"
    elif (( realized_pl < 0 )); then
        printf "Realized P/L:       \033[31m%s IRR\033[0m\n" "$realized_pl"
    else
        printf "Realized P/L:       \033[33m0 IRR\033[0m\n"
    fi
	echo

    if (( invalid )); then
        echo "Warning: Wallet contains invalid or incomplete entries."
        return 1
    fi
}


buy_crypto() {
    local symbol="${1^^}"
    local amount="$2"
    local history_file last_line
    local current_price current_usd quantity
    local old_quantity=0 old_avg=0
    local new_quantity new_avg
    local cash=0 new_cash
    local found_cash=0 found_asset=0
    local temp_file timestamp
    local wallet_symbol wallet_quantity wallet_avg line

    # Validate arguments
    if [[ -z "$symbol" || ! "$amount" =~ ^[0-9]+$ ]] || (( amount <= 0 )); then
        echo "Usage: epmarket --buy SYMBOL AMOUNT_IRR"
        return 1
    fi

    # Check symbol
    if ! grep -Fxq "$symbol" "$SYMBOLS_FILE"; then
        echo "Error: Unknown symbol $symbol."
        return 1
    fi

    # Get latest price
    history_file="$DB_DIR/-$symbol.txt"

    if [[ ! -s "$history_file" ]]; then
        echo "Error: No price history for $symbol. Run -u first."
        return 1
    fi

    last_line=$(tail -n 1 "$history_file")
    current_usd=$(awk '{print $5}' <<< "$last_line")
    current_price=$(awk '{print $8}' <<< "$last_line")

    if [[ ! "$current_price" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v p="$current_price" 'BEGIN {exit (p > 0) ? 0 : 1}'; then
        echo "Error: Invalid price for $symbol."
        return 1
    fi

    # Calculate quantity
    quantity=$(awk -v a="$amount" -v p="$current_price" \
        'BEGIN {printf "%.8f", a/p}')

    # Read wallet
    while IFS=: read -r wallet_symbol wallet_quantity wallet_avg; do
        wallet_symbol=$(xargs <<< "$wallet_symbol")

        if [[ "$wallet_symbol" == "CASH_IRR" ]]; then
            if (( found_cash )); then
                echo "Error: Duplicate cash entries in wallet."
                return 1
            fi
            cash=$(xargs <<< "$wallet_quantity")
            found_cash=1

        elif [[ "$wallet_symbol" == "$symbol" ]]; then
            if (( found_asset )); then
                echo "Error: Duplicate $symbol entries in wallet."
                return 1
            fi
            old_quantity=$(xargs <<< "$wallet_quantity")
            old_avg=$(xargs <<< "$wallet_avg")
            found_asset=1
        fi
    done < "$WALLET_FILE"

    if (( ! found_cash )) || [[ ! "$cash" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid cash balance in wallet."
        return 1
    fi

    if (( cash < amount )); then
        echo "Error: Insufficient cash balance."
        return 1
    fi

    # Calculate new balance and average price
    new_cash=$((cash - amount))

    if (( found_asset )); then
        if [[ ! "$old_quantity" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
           [[ ! "$old_avg" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "Error: Invalid existing asset entry."
            return 1
        fi

        new_quantity=$(awk -v old="$old_quantity" -v new="$quantity" \
            'BEGIN {printf "%.8f", old+new}')

        new_avg=$(awk -v oq="$old_quantity" -v oa="$old_avg" \
            -v nq="$quantity" -v na="$current_price" \
            'BEGIN {printf "%.0f", (oq*oa+nq*na)/(oq+nq)}')
    else
        new_quantity="$quantity"
        new_avg="$current_price"
    fi

    # Update wallet
    temp_file=$(mktemp "$DB_DIR/wallet.XXXXXX") || return 1

    while IFS= read -r line; do
        wallet_symbol="${line%%:*}"
        wallet_symbol=$(xargs <<< "$wallet_symbol")

        if [[ "$wallet_symbol" == "CASH_IRR" ]]; then
            echo "CASH_IRR: $new_cash" >> "$temp_file"
        elif [[ "$wallet_symbol" == "$symbol" ]]; then
            echo "$symbol: $new_quantity: $new_avg" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$WALLET_FILE"

    if (( ! found_asset )); then
        echo "$symbol: $new_quantity: $new_avg" >> "$temp_file"
    fi

    if ! mv "$temp_file" "$WALLET_FILE"; then
        rm -f "$temp_file"
        echo "Error: Could not update wallet."
        return 1
    fi

    # Log trade
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [BUY] $symbol | $quantity | $current_usd | $current_price | $amount | -" \
        >> "$TRADES_LOG"

    echo "Successfully bought $quantity $symbol."
    echo "Unit price: $current_price IRR"
    echo "Total cost: $amount IRR"
    echo "Remaining cash: $new_cash IRR"
}


sell_crypto() {
    local symbol="${1^^}"
    local history_file
    local last_line
    local current_usd
    local current_price
    local quantity=""
    local avg_price=""
    local cash=""
    local found_cash=0
    local found_asset=0
    local sale_value
    local cost_basis
    local realized_pl
    local new_cash
    local temp_file
    local timestamp
    local wallet_symbol
    local wallet_quantity
    local wallet_avg
    local line
    local action="${2:-SELL}"


    # Validate argument
    if [[ -z "$symbol" ]]; then
        echo "Usage: epmarket --sell SYMBOL"
        return 1
    fi

    # Check symbol
    if ! grep -Fxq "$symbol" "$SYMBOLS_FILE"; then
        echo "Error: Unknown symbol $symbol."
        return 1
    fi

    # Read latest price
    history_file="$DB_DIR/-$symbol.txt"

    if [[ ! -s "$history_file" ]]; then
        echo "Error: No price history for $symbol. Run -u first."
        return 1
    fi

    last_line=$(tail -n 1 "$history_file")
    current_usd=$(awk '{print $5}' <<< "$last_line")
    current_price=$(awk '{print $8}' <<< "$last_line")

    if [[ ! "$current_price" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v p="$current_price" 'BEGIN {exit (p > 0) ? 0 : 1}'; then
        echo "Error: Invalid price for $symbol."
        return 1
    fi

    # Read wallet
    while IFS=: read -r wallet_symbol wallet_quantity wallet_avg; do
        wallet_symbol=$(xargs <<< "$wallet_symbol")

        if [[ "$wallet_symbol" == "CASH_IRR" ]]; then
            if (( found_cash )); then
                echo "Error: Duplicate cash entries in wallet."
                return 1
            fi

            cash=$(xargs <<< "$wallet_quantity")
            found_cash=1

        elif [[ "$wallet_symbol" == "$symbol" ]]; then
            if (( found_asset )); then
                echo "Error: Duplicate $symbol entries in wallet."
                return 1
            fi

            quantity=$(xargs <<< "$wallet_quantity")
            avg_price=$(xargs <<< "$wallet_avg")
            found_asset=1
        fi
    done < "$WALLET_FILE"

    if (( ! found_cash )) || [[ ! "$cash" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid cash balance in wallet."
        return 1
    fi

    if (( ! found_asset )); then
        echo "Error: You don't own any $symbol."
        return 1
    fi

    if [[ ! "$quantity" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       [[ ! "$avg_price" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       ! awk -v q="$quantity" -v p="$avg_price" \
           'BEGIN {exit (q > 0 && p > 0) ? 0 : 1}'; then
        echo "Error: Invalid asset entry for $symbol."
        return 1
    fi

    # Calculate sale value and realized profit/loss
    sale_value=$(awk -v q="$quantity" -v p="$current_price" \
        'BEGIN {printf "%.0f", q*p}')

    cost_basis=$(awk -v q="$quantity" -v p="$avg_price" \
        'BEGIN {printf "%.0f", q*p}')

    realized_pl=$((sale_value - cost_basis))
    new_cash=$((cash + sale_value))

    # Update wallet
    temp_file=$(mktemp "$DB_DIR/wallet.XXXXXX") || return 1

    while IFS= read -r line; do
        wallet_symbol="${line%%:*}"
        wallet_symbol=$(xargs <<< "$wallet_symbol")

        if [[ "$wallet_symbol" == "$symbol" ]]; then
            continue
        elif [[ "$wallet_symbol" == "CASH_IRR" ]]; then
            echo "CASH_IRR: $new_cash" >> "$temp_file"
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$WALLET_FILE"

    if ! mv "$temp_file" "$WALLET_FILE"; then
        rm -f "$temp_file"
        echo "Error: Could not update wallet."
        return 1
    fi

    # Log trade
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$action] $symbol | $quantity | $current_usd | $current_price | $sale_value | $realized_pl" \
        >> "$TRADES_LOG"

    echo "Successfully sold $quantity $symbol."
    echo "Unit price: $current_price IRR"
    echo "Sale value: $sale_value IRR"
    echo "Realized P/L: $realized_pl IRR"
    echo "New cash balance: $new_cash IRR"
}


create_order() {
    local symbol="${1^^}"
    local min_usd="$2"
    local max_usd="$3"
    local buy_amount="$4"

    # Validate arguments
    if [[ -z "$symbol" || -z "$min_usd" || -z "$max_usd" || -z "$buy_amount" ]]; then
        echo "Usage: epmarket --order SYMBOL MIN_USD MAX_USD BUY_AMOUNT_IRR"
        return 1
    fi

    # Validate symbol
    if ! grep -Fxq "$symbol" "$SYMBOLS_FILE"; then
        echo "Error: Unknown symbol $symbol."
        return 1
    fi

    # Validate numeric values
    if [[ ! "$min_usd" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       [[ ! "$max_usd" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
       [[ ! "$buy_amount" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid numeric values."
        return 1
    fi

    # Validate price range and buy amount
    if ! awk -v min="$min_usd" -v max="$max_usd" \
        'BEGIN {exit (min > 0 && max >= min) ? 0 : 1}'; then
        echo "Error: Invalid price range."
        return 1
    fi

    if (( buy_amount <= 0 )); then
        echo "Error: Buy amount must be greater than zero."
        return 1
    fi

    # Save order
    echo "$symbol | $min_usd | $max_usd | $buy_amount | ACTIVE" >> "$ORDERS_FILE"

    echo "Order created successfully!"
    echo "Symbol: $symbol"
    echo "Price range: $min_usd - $max_usd USD"
    echo "Buy amount: $buy_amount IRR"
    echo "Status: ACTIVE"
}


process_orders() {
    local temp_file
    local symbol min_usd max_usd amount status
    local history_file last_line current_usd
    local line

    [[ -s "$ORDERS_FILE" ]] || return 0

    temp_file=$(mktemp "$DB_DIR/orders.XXXXXX") || return 1

    echo "Checking conditional orders..."

    while IFS='|' read -r symbol min_usd max_usd amount status; do
        symbol=$(xargs <<< "$symbol")
        min_usd=$(xargs <<< "$min_usd")
        max_usd=$(xargs <<< "$max_usd")
        amount=$(xargs <<< "$amount")
        status=$(xargs <<< "$status")

        if [[ "$status" != "ACTIVE" ]]; then
            echo "$symbol | $min_usd | $max_usd | $amount | $status" >> "$temp_file"
            continue
        fi

        history_file="$DB_DIR/-$symbol.txt"

        if [[ ! -s "$history_file" ]]; then
            echo "$symbol | $min_usd | $max_usd | $amount | $status" >> "$temp_file"
            continue
        fi

        last_line=$(tail -n 1 "$history_file")
        current_usd=$(awk '{print $5}' <<< "$last_line")

        if ! awk -v p="$current_usd" \
            'BEGIN {exit (p ~ /^[0-9]+([.][0-9]+)?$/ && p > 0) ? 0 : 1}'; then
            echo "$symbol | $min_usd | $max_usd | $amount | $status" >> "$temp_file"
            continue
        fi

        if awk -v p="$current_usd" -v min="$min_usd" -v max="$max_usd" \
            'BEGIN {exit (p >= min && p <= max) ? 0 : 1}'; then

            echo "Order triggered: $symbol at $current_usd USD"

            if buy_crypto "$symbol" "$amount"; then
                status="EXECUTED"
            else
                echo "Order not executed: $symbol"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MISSED_TRADE] $symbol | BUY_FAILED | $current_usd | Insufficient funds or buy error" \
                    >> "$MISSED_TRADES_LOG"
            fi
        fi

        echo "$symbol | $min_usd | $max_usd | $amount | $status" >> "$temp_file"

    done < "$ORDERS_FILE"

    if ! mv "$temp_file" "$ORDERS_FILE"; then
        rm -f "$temp_file"
        echo "Error: Could not update orders file."
        return 1
    fi

    echo "Order processing completed."
}


process_stop_losses() {
    local symbol quantity avg_price
    local history_file last_line current_price
    local stop_price
    local wallet_symbol wallet_quantity wallet_avg
    local updated_symbol found

    [[ -s "$WALLET_FILE" ]] || return 0

    echo "Checking stop-loss conditions..."

    while IFS=: read -r wallet_symbol wallet_quantity wallet_avg; do
        symbol=$(xargs <<< "$wallet_symbol")
        quantity=$(xargs <<< "$wallet_quantity")
        avg_price=$(xargs <<< "$wallet_avg")

        [[ "$symbol" == "CASH_IRR" ]] && continue
        [[ -n "$symbol" ]] || continue

        # Check whether this symbol was updated successfully.
        found=0
        for updated_symbol in "$@"; do
            if [[ "$updated_symbol" == "$symbol" ]]; then
                found=1
                break
            fi
        done

        if (( ! found )); then
            echo "Skipping $symbol: No fresh price available."
            continue
        fi

        if [[ ! "$quantity" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
           [[ ! "$avg_price" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "Warning: Invalid wallet entry for $symbol. Skipping."
            continue
        fi

        history_file="$DB_DIR/-$symbol.txt"

        if [[ ! -s "$history_file" ]]; then
            continue
        fi

        last_line=$(tail -n 1 "$history_file")
        current_price=$(awk '{print $8}' <<< "$last_line")

        if [[ ! "$current_price" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            continue
        fi

        stop_price=$(awk -v avg="$avg_price" -v percent="$STOP_LOSS_PERCENT" \
            'BEGIN {printf "%.8f", avg*(1-percent/100)}')

        if awk -v current="$current_price" -v stop="$stop_price" \
            'BEGIN {exit (current <= stop) ? 0 : 1}'; then

            echo "STOP-LOSS TRIGGERED: $symbol"
            echo "Average buy price: $avg_price IRR"
            echo "Current price: $current_price IRR"
            echo "Stop-loss price: $stop_price IRR"

            if sell_crypto "$symbol" "STOP_LOSS"; then
                echo "Stop-loss completed for $symbol."
            else
                echo "Error: Stop-loss failed for $symbol."
            fi
        fi

    done < "$WALLET_FILE"

    echo "Stop-loss check completed."
}


show_statement() {
    if [[ ! -s "$TRADES_LOG" ]]; then
        echo "No trading history available."
        return 0
    fi

    awk -F'|' '
    function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }

    function color_pl(value) {
        if (value > 0)
            return "\033[32m"
        else if (value < 0)
            return "\033[31m"
        else
            return "\033[33m"
    }

    BEGIN {
        cyan = "\033[36m"
        yellow = "\033[33m"
        reset = "\033[0m"
        bold = "\033[1m"
    }

    {
        header = trim($1)

        sub(/^.*\] \[/, "", header)
        split(header, parts, "] ")

        action = trim(parts[1])
        symbol = trim(parts[2])

        quantity = trim($2) + 0
        total = trim($5) + 0
        profit_loss = trim($6) + 0

        if (symbol == "" || (action != "BUY" &&
            action != "SELL" && action != "STOP_LOSS"))
            next

        if (!(symbol in seen)) {
            seen[symbol] = 1
            symbols[++symbol_count] = symbol
        }

        if (action == "BUY") {
            buys++
            buy_total += total
            symbol_buys[symbol]++
            symbol_buy_total[symbol] += total
        } else {
            sells++
            sell_total += total
            realized_pl += profit_loss
            symbol_sells[symbol]++
            symbol_sell_total[symbol] += total
            symbol_pl[symbol] += profit_loss

            if (action == "STOP_LOSS") {
                stop_losses++
                stop_loss_total += total
                symbol_stop_losses[symbol]++
            }
        }
    }

    END {
        printf "%s%s========== TRADING STATEMENT ==========%s\n", bold, cyan, reset

        printf "Total BUY transactions:       %d\n", buys
        printf "Total SELL transactions:      %d\n", sells

        printf "%sTotal STOP-LOSS transactions: %d%s\n", \
            yellow, stop_losses, reset

        print "---------------------------------------"

        printf "Total buy value:  %.0f IRR\n", buy_total
        printf "Total sell value: %.0f IRR\n", sell_total

        printf "%sStop-loss value:  %.0f IRR%s\n", \
            yellow, stop_loss_total, reset

        printf "Realized P/L:     %s%.0f IRR%s\n", \
            color_pl(realized_pl), realized_pl, reset

        print "---------------------------------------"

        printf "%sPER-SYMBOL PERFORMANCE%s\n", cyan, reset

        for (i = 1; i <= symbol_count; i++) {
            s = symbols[i]

            printf "\n%s%s%s\n", bold, s, reset

            printf "  Buys:       %d (%.0f IRR)\n", \
                symbol_buys[s], symbol_buy_total[s]

            printf "  Sells:      %d (%.0f IRR)\n", \
                symbol_sells[s], symbol_sell_total[s]

            printf "  Stop-Loss:  %s%d%s\n", \
                yellow, symbol_stop_losses[s], reset

            printf "  Realized P/L: %s%.0f IRR%s\n", \
                color_pl(symbol_pl[s]), symbol_pl[s], reset
        }

        printf "\n%s=======================================%s\n", cyan, reset
    }
    ' "$TRADES_LOG"
}

manage_orders() {
    while true; do
        clear

        echo "========== CONDITIONAL ORDERS =========="
        echo
        echo "1. Create New Order"
        echo "2. View Orders"
        echo "3. Back to Main Menu"
        echo
        read -rp "Select an option: " choice

        case "$choice" in
            1)
                read -rp "Symbol: " symbol
                read -rp "Minimum USD Price: " min_price
                read -rp "Maximum USD Price: " max_price
                read -rp "Buy Amount (IRR): " amount

                create_order "$symbol" "$min_price" "$max_price" "$amount"

                read -rp "Press Enter to continue..."
                ;;
            2)
                cat "$ORDERS_FILE"
                echo
                read -rp "Press Enter to continue..."
                ;;
            3)
                return 0
                ;;
            *)
                echo "Invalid option!"
                sleep 1
                ;;
        esac
    done
}

show_menu() {
    local options=(
        "Market Prices"
        "My Wallet"
        "Buy Cryptocurrency"
        "Sell Cryptocurrency"
        "Conditional Orders"
        "Trading Statement"
        "Update Prices"
        "Exit"
    )

    local selected=0
    local key
    local count=${#options[@]}
    local cash
    local symbols_count
    local latest_file
    local last_update
    local i symbol amount
    local btc_price
    local eth_price
    local get_latest_price

    while true; do
        clear

        cash=$(awk -F: '$1=="CASH_IRR" {gsub(/[[:space:]]/, "", $2); print $2}' "$WALLET_FILE")
        symbols_count=$(awk 'NF {count++} END {print count+0}' "$SYMBOLS_FILE")

        latest_file=$(find "$DB_DIR" -maxdepth 1 -type f -name '-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)

        if [[ -n "$latest_file" ]]; then
            last_update=$(date -r "$latest_file" '+%Y-%m-%d %H:%M:%S')
        else
            last_update="Not available"
        fi

	btc_price=$(awk 'END {
    	    if (NR > 0) print $8
    	    else print "N/A"
	}' "$DB_DIR/-BTC.txt")

	eth_price=$(awk 'END {
	    if (NR > 0) print $8
	    else print "N/A"
	}' "$DB_DIR/-ETH.txt")
        
	tput setaf 6
        echo "=================================================="
        echo "             EMPEROR PENGUIN MARKET"
        echo "=================================================="
        tput sgr0

        echo
        printf "  Wallet Balance : %s IRR\n" "${cash:-0}"
	printf "  Monitored Coins: %s\n" "$symbols_count"
	printf "  BTC Price      : %s IRR\n" "$btc_price"
	printf "  ETH Price      : %s IRR\n" "$eth_price"
	printf "  Last Update    : %s\n" "$last_update"
	printf "  System Status  : READY\n"

        echo
        tput setaf 6
        echo "-------------------- MAIN MENU -------------------"
        tput sgr0
        echo

        for ((i=0; i<count; i++)); do
            if (( i == selected )); then
                tput setaf 2
                tput bold
                printf "       > %s\n" "${options[i]}"
                tput sgr0
            else
                printf "         %s\n" "${options[i]}"
            fi
        done

        echo
        tput setaf 6
        echo "--------------------------------------------------"
        tput sgr0
        echo "       UP/DOWN: Navigate   ENTER: Select"
        echo "                  Q: Quit"
        echo

        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key

            case "$key" in
                '[A')
                    selected=$((selected - 1))
                    (( selected < 0 )) && selected=$((count - 1))
                    ;;
                '[B')
                    selected=$((selected + 1))
                    (( selected >= count )) && selected=0
                    ;;
            esac

        elif [[ "$key" == "" ]]; then
            case "$selected" in
                0) list_prices ;;
                1) show_wallet ;;
                2)
                    read -rp "Symbol: " symbol
                    read -rp "Amount (IRR): " amount
                    buy_crypto "$symbol" "$amount"
                    ;;
                3)
                    read -rp "Symbol: " symbol
                    sell_crypto "$symbol"
                    ;;
                4) manage_orders ;;
                5) show_statement ;;
                6) update_prices ;;
                7) return 0 ;;
            esac

            echo
            read -rp "Press Enter to return to menu..."
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            return 0
        fi
    done
}


main() {
    case "$1" in
	-i)
    	    show_menu
    	    ;;
        -h)
            show_help
            ;;
        -l)
            echo "Listing monitored symbols..."
	    list_prices
            ;;
        -u)
            echo "Updating prices and processing orders..."
	    update_prices
            ;;
        --wallet)
            echo "Displaying wallet..."
	    show_wallet
            ;;
        --statement)
            echo "Displaying trading statement..."
	    show_statement
            ;;
	-a)
    	    if [[ $# -ne 2 ]]; then
        	echo "Usage: epmarket -a SYMBOL"
        	return 1
	    fi

    	    symbol="${2^^}"

	    if validate_symbol "$symbol"; then
        	echo "Error: $symbol is already monitored."
      		return 1
    	    fi

    	    http_code=$(check_api_symbol "$symbol")

    	    if [[ "$http_code" == "200" ]]; then
        	echo "$symbol" >> "$SYMBOLS_FILE"
        	touch "$DB_DIR/-$symbol.txt"
        	echo "$symbol added successfully."
    	    else
        	echo "Error: Invalid symbol or API request failed (HTTP $http_code)."
        	return 1
    	    fi
    	    ;;
        -d)
    	    if [[ $# -ne 2 ]]; then
                echo "Usage: epmarket -d SYMBOL"
                return 1
    	    fi

    	    if validate_symbol "$2"; then
        	sed -i "/^$2$/d" "$SYMBOLS_FILE"
        	echo "$2 removed successfully."
    	    else
        	echo "Error: $2 is not in the monitored symbols list."
        	return 1
    	    fi
   	    ;;
        --buy)
            if [[ $# -ne 3 ]]; then
                echo "Usage: epmarket --buy SYMBOL AMOUNT_IRR"
                return 1
            fi
            buy_crypto "$2" "$3"
            ;;
        --sell)
            if [[ $# -ne 2 ]]; then
                echo "Usage: epmarket --sell SYMBOL"
                return 1
            fi
            sell_crypto "$2"
            ;;
        --order)
            if [[ $# -ne 5 ]]; then
                echo "Usage: epmarket --order SYMBOL MIN_USD MAX_USD BUY_AMOUNT_IRR"
                return 1
            fi
            create_order "$2" "$3" "$4" "$5"
            ;;
        "")
            show_help
            ;;
        *)
            echo "Error: Unknown option '$1'"
            echo "Use -h to see available options."
            return 1
            ;;
    esac
}

validate_symbol(){

    if grep -Fxq "$1" "$SYMBOLS_FILE"; then
        return 0
    else
        return 1
    fi
}

exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "Another instance of epmarket is already running."
    exit 1
fi

main "$@"

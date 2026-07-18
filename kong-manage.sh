#!/bin/bash

# ==============================================================================
# BIẾN CỐ ĐỊNH HỆ THỐNG (Đã đổi về Localhost theo yêu cầu)
# ==============================================================================
KONG_ADMIN="http://localhost:8001"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# HÀM TIỆN ÍCH: trích danh sách 'name/username' hoặc 'id' từ Admin API
# ------------------------------------------------------------------------------
# $1 = đường dẫn Admin API (ví dụ /services). In ra mỗi dòng 1 tên.
list_names() {
    curl -s "${KONG_ADMIN}$1" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print(' -', x.get('name') or x.get('username') or x.get('id'))" 2>/dev/null
}

# $1 = đường dẫn Admin API trả {data:[{id:...}]}. In ra mỗi dòng 1 id.
get_ids() {
    curl -s "${KONG_ADMIN}$1" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print(x.get('id'))" 2>/dev/null
}

# ==============================================================================
# TÁC VỤ 1: TẠO MỚI TOÀN BỘ (Service + Route + Consumer + Bảo mật 3 lớp)
# ==============================================================================
task_create_full() {
    echo -e "\n${GREEN}[TÁC VỤ: TẠO MỚI TOÀN BỘ SYSTEM]${NC}"
    echo "Chọn loại ứng dụng gốc bạn muốn tối ưu:"
    echo "1) Cấu hình kiểu N8N (Sử dụng Header 'x-api-key')"
    echo "2) Cấu hình kiểu Dify (Sử dụng Header 'Authorization')"
    read -p "Lựa chọn (1 hoặc 2): " APP_TYPE

    echo -e "\n👉 VUI LÒNG NHẬP THÔNG TIN:"
    read -p "➔ Nhập URL VLLM BACKEND (Ví dụ: http://107.118.109.36:8000): " VLLM_BACKEND

    read -p "1. Nhập TÊN SERVICE (Ví dụ: vllm060-dify-service): " SERVICE_NAME
    read -p "2. Nhập TÊN ROUTE (Ví dụ: vllm06-dify-route): " ROUTE_NAME
    read -p "3. Nhập ĐƯỜNG DẪN PATH (Ví dụ: /vllm06-dify): " ROUTE_PATH
    read -p "4. Nhập TÊN CONSUMER BAN ĐẦU (Ví dụ: dify_app): " CONSUMER_NAME
    read -p "5. Nhập CHUỖI API KEY cấp cho app này: " RAW_KEY
    read -p "6. Nhập TÊN NHÓM ACL MỚI (Ví dụ: dify_group): " ACL_GROUP
    read -p "7. Nhập IP MÁY CHỦ ĐƯỢC PHÉP TRUY CẬP (Để trống nếu mở Public): " ALLOWED_IPS

    # Xử lý format Key
    if [ "$APP_TYPE" == "2" ]; then
        HEADER_TYPE="Authorization"
        FINAL_KEY="Bearer ${RAW_KEY}"
    else
        HEADER_TYPE="x-api-key"
        FINAL_KEY="${RAW_KEY}"
    fi

    echo -e "\n🚀 Đang triển khai cụm dịch vụ..."

    curl -s -o /dev/null -w "   - Khởi tạo Service: %{http_code}\n" -X POST ${KONG_ADMIN}/services --data name="${SERVICE_NAME}" --data url="${VLLM_BACKEND}" --data connect_timeout=60000 --data read_timeout=600000 --data write_timeout=600000
    curl -s -o /dev/null -w "   - Khởi tạo Route: %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/routes --data name="${ROUTE_NAME}" --data paths[]="${ROUTE_PATH}" --data strip_path=true
    curl -s -o /dev/null -X POST ${KONG_ADMIN}/consumers/ --data username="${CONSUMER_NAME}"
    curl -s -o /dev/null -w "   - Cấp phát API Key: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/${CONSUMER_NAME}/key-auth --data key="${FINAL_KEY}"
    curl -s -o /dev/null -w "   - Tạo nhóm ACL [${ACL_GROUP}]: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/${CONSUMER_NAME}/acls --data "group=${ACL_GROUP}"
    curl -s -o /dev/null -w "   - Kích hoạt lớp 1 (Key-Auth): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=key-auth --data config.key_names="${HEADER_TYPE}"
    curl -s -o /dev/null -w "   - Kích hoạt lớp 2 (ACL Whitelist): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=acl --data config.allow="${ACL_GROUP}"

    if [ ! -z "${ALLOWED_IPS}" ]; then
        curl -s -o /dev/null -w "   - Kích hoạt lớp 3 (IP Restriction): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=ip-restriction --data config.allow="${ALLOWED_IPS}"
    fi

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}✔ HOÀN THÀNH: Đã tạo xong cụm Service & Route bảo mật thành công!${NC}"
    echo "• API URL: http://${SERVER_IP}:8000${ROUTE_PATH}/v1"
    echo "• API Key: ${RAW_KEY}"
}

# ==============================================================================
# TÁC VỤ 2: CHỈ THÊM CONSUMER MỚI VÀO HỆ THỐNG SẴN CÓ
# ==============================================================================
task_add_consumer() {
    echo -e "\n${YELLOW}[TÁC VỤ: THÊM CONSUMER VÀO SERVICE ĐÃ CÓ]${NC}"

    read -p "1. Nhập TÊN CONSUMER MỚI (Ví dụ: flowise_app): " CONSUMER_NAME
    read -p "2. Nhập MÃ CHUỖI API KEY cấp cho app mới này: " RAW_KEY
    read -p "3. Nhập CHÍNH XÁC TÊN NHÓM ACL của Service cũ (Ví dụ: dify_group): " ACL_GROUP

    echo "Chọn định dạng Header của Service cũ mà app này sẽ gọi vào:"
    echo "1) Định dạng thông thường (Header 'x-api-key' - Kiểu N8N)"
    echo "2) Định dạng Authorization (Header 'Authorization' kèm Bearer - Kiểu Dify)"
    read -p "Lựa chọn (1 hoặc 2): " KEY_TYPE

    if [ "$KEY_TYPE" == "2" ]; then
        FINAL_KEY="Bearer ${RAW_KEY}"
    else
        FINAL_KEY="${RAW_KEY}"
    fi

    echo -e "\n🚀 Đang cấp quyền cho Consumer mới..."

    curl -s -o /dev/null -w "   - Tạo Consumer mới [${CONSUMER_NAME}]: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/ --data username="${CONSUMER_NAME}"
    curl -s -o /dev/null -w "   - Cấp phát API Key bảo mật: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/${CONSUMER_NAME}/key-auth --data key="${FINAL_KEY}"
    curl -s -o /dev/null -w "   - Đóng mộc tham gia nhóm ACL [${ACL_GROUP}]: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/${CONSUMER_NAME}/acls --data "group=${ACL_GROUP}"

    echo -e "\n${GREEN}✔ HOÀN THÀNH: Đã gán quyền thành công cho ${CONSUMER_NAME}!${NC}"
    echo "App mới này hiện tại có thể dùng chung Service cũ bằng mã Key: ${RAW_KEY}"
}

# ==============================================================================
# TÁC VỤ 3: TỔNG QUAN TOÀN BỘ CẤU HÌNH HIỆN TẠI
#   Cây: Service → backend → Route → Plugin ; và Consumer → ACL group + số key
# ==============================================================================
task_overview() {
    echo -e "\n${CYAN}==================== TỔNG QUAN CẤU HÌNH KONG ====================${NC}"

    # ---- SERVICES (kèm backend + Route + Plugin) ----
    echo -e "\n${GREEN}### SERVICES / ROUTES / PLUGINS${NC}"
    SVC_NAMES=$(curl -s "${KONG_ADMIN}/services" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print(x.get('name') or x.get('id'))" 2>/dev/null)

    if [ -z "$SVC_NAMES" ]; then
        echo "  (chưa có service nào)"
    fi

    for S in $SVC_NAMES; do
        # Thông tin backend của service
        curl -s "${KONG_ADMIN}/services/${S}" | python3 -c "import sys,json
try:
    x=json.load(sys.stdin)
except Exception:
    x={}
proto=x.get('protocol'); host=x.get('host'); port=x.get('port'); path=x.get('path') or ''
print('\n● Service: %s' % x.get('name'))
print('   backend : %s://%s:%s%s' % (proto, host, port, path))" 2>/dev/null

        # Routes trực thuộc
        curl -s "${KONG_ADMIN}/services/${S}/routes" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for r in d:
    print('   route   : %-24s paths=%s strip=%s' % (r.get('name'), r.get('paths'), r.get('strip_path')))" 2>/dev/null

        # Plugins trực thuộc (hiện cấu hình chính của từng loại)
        curl -s "${KONG_ADMIN}/services/${S}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for p in d:
    n=p.get('name'); c=p.get('config',{}) or {}
    extra=''
    if n=='key-auth':        extra='key_names=%s' % c.get('key_names')
    elif n=='acl':           extra='allow=%s' % c.get('allow')
    elif n=='ip-restriction':extra='allow=%s' % c.get('allow')
    elif n=='rate-limiting': extra='minute=%s hour=%s' % (c.get('minute'), c.get('hour'))
    print('   plugin  : %-16s %s' % (n, extra))" 2>/dev/null
    done

    # ---- CONSUMERS (kèm ACL group + số API key) ----
    echo -e "\n${GREEN}### CONSUMERS (ACL group + số API key)${NC}"
    CON_NAMES=$(curl -s "${KONG_ADMIN}/consumers" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print(x.get('username') or x.get('id'))" 2>/dev/null)

    if [ -z "$CON_NAMES" ]; then
        echo "  (chưa có consumer nào)"
    fi

    for C in $CON_NAMES; do
        GROUPS=$(curl -s "${KONG_ADMIN}/consumers/${C}/acls" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
print(','.join(x.get('group','') for x in d) or '-')" 2>/dev/null)
        KEYS=$(curl -s "${KONG_ADMIN}/consumers/${C}/key-auth" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
print(len(d))" 2>/dev/null)
        printf "   ● %-20s acl=%-18s keys=%s\n" "$C" "$GROUPS" "$KEYS"
    done

    echo -e "\n${CYAN}================================================================${NC}"
}

# ==============================================================================
# TÁC VỤ 4: LIỆT KÊ NHANH 1 NHÓM (Services / Routes / Consumers / Plugins)
# ==============================================================================
task_list() {
    echo -e "\n${CYAN}[TÁC VỤ: LIỆT KÊ NHANH]${NC}"
    echo "1) Tất cả Services"
    echo "2) Tất cả Routes"
    echo "3) Tất cả Consumers"
    echo "4) Plugins của 1 Service cụ thể"
    read -p "Lựa chọn (1-4): " L

    case "$L" in
        1)
            echo -e "\n${GREEN}» Danh sách SERVICES:${NC}"
            list_names /services
            ;;
        2)
            echo -e "\n${GREEN}» Danh sách ROUTES:${NC}"
            list_names /routes
            ;;
        3)
            echo -e "\n${GREEN}» Danh sách CONSUMERS:${NC}"
            list_names /consumers
            ;;
        4)
            echo -e "\n${GREEN}» Services hiện có:${NC}"
            list_names /services
            read -p "Nhập TÊN SERVICE cần xem plugin: " SNAME
            echo -e "\n${GREEN}» Plugins của [${SNAME}]:${NC}"
            curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print(' -', x.get('name'), '| enabled:', x.get('enabled'))" 2>/dev/null
            ;;
        *)
            echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
            ;;
    esac
}

# ==============================================================================
# TÁC VỤ 5: XÓA (Service kèm route+plugin, hoặc Consumer)
# ==============================================================================
task_delete() {
    echo -e "\n${RED}[TÁC VỤ: XÓA CẤU HÌNH]${NC}"
    echo "1) Xóa 1 SERVICE (tự xóa hết Route + Plugin trực thuộc rồi xóa Service)"
    echo "2) Xóa 1 CONSUMER (tự gỡ Key + ACL của consumer đó)"
    read -p "Lựa chọn (1 hoặc 2): " D

    if [ "$D" == "1" ]; then
        echo -e "\n${GREEN}» Services hiện có:${NC}"
        list_names /services
        read -p "Nhập TÊN SERVICE cần XÓA: " SNAME
        [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }
        read -p "⚠  Gõ '${SNAME}' lần nữa để xác nhận XÓA: " CONFIRM
        [ "$CONFIRM" != "$SNAME" ] && { echo -e "${RED}Hủy: xác nhận không khớp.${NC}"; return; }

        echo -e "\n🗑  Đang xóa Route trực thuộc..."
        for RID in $(get_ids "/services/${SNAME}/routes"); do
            curl -s -o /dev/null -w "   - Xóa Route ${RID}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/routes/${RID}"
        done
        echo "🗑  Đang xóa Plugin trực thuộc..."
        for PID in $(get_ids "/services/${SNAME}/plugins"); do
            curl -s -o /dev/null -w "   - Xóa Plugin ${PID}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/plugins/${PID}"
        done
        curl -s -o /dev/null -w "   - Xóa Service ${SNAME}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/services/${SNAME}"
        echo -e "${GREEN}✔ Đã xóa Service [${SNAME}].${NC}"

    elif [ "$D" == "2" ]; then
        echo -e "\n${GREEN}» Consumers hiện có:${NC}"
        list_names /consumers
        read -p "Nhập TÊN CONSUMER cần XÓA: " CNAME
        [ -z "$CNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }
        read -p "⚠  Gõ '${CNAME}' lần nữa để xác nhận XÓA: " CONFIRM
        [ "$CONFIRM" != "$CNAME" ] && { echo -e "${RED}Hủy: xác nhận không khớp.${NC}"; return; }
        # Xóa consumer sẽ tự cascade key-auth + acls
        curl -s -o /dev/null -w "   - Xóa Consumer ${CNAME}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/consumers/${CNAME}"
        echo -e "${GREEN}✔ Đã xóa Consumer [${CNAME}] (kèm Key + ACL).${NC}"
    else
        echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    fi
}

# ==============================================================================
# TÁC VỤ 6: THU HỒI / ĐỔI API KEY của 1 Consumer
# ==============================================================================
task_rotate_key() {
    echo -e "\n${YELLOW}[TÁC VỤ: THU HỒI / ĐỔI API KEY]${NC}"
    echo -e "${GREEN}» Consumers hiện có:${NC}"
    list_names /consumers
    read -p "Nhập TÊN CONSUMER cần đổi key: " CNAME
    [ -z "$CNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }

    echo -e "\n🗑  Thu hồi toàn bộ key cũ của [${CNAME}]..."
    for KID in $(get_ids "/consumers/${CNAME}/key-auth"); do
        curl -s -o /dev/null -w "   - Thu hồi key ${KID}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/consumers/${CNAME}/key-auth/${KID}"
    done

    read -p "Nhập CHUỖI API KEY MỚI: " RAW_KEY
    echo "Định dạng Header của Service mà consumer này gọi vào:"
    echo "1) x-api-key (Kiểu N8N)"
    echo "2) Authorization + Bearer (Kiểu Dify)"
    read -p "Lựa chọn (1 hoặc 2): " KEY_TYPE
    if [ "$KEY_TYPE" == "2" ]; then
        FINAL_KEY="Bearer ${RAW_KEY}"
    else
        FINAL_KEY="${RAW_KEY}"
    fi

    curl -s -o /dev/null -w "   - Cấp key mới: %{http_code}\n" -X POST ${KONG_ADMIN}/consumers/${CNAME}/key-auth --data key="${FINAL_KEY}"
    echo -e "${GREEN}✔ Đã đổi key cho [${CNAME}]. Key mới: ${RAW_KEY}${NC}"
}

# ==============================================================================
# TÁC VỤ 7: ĐỔI BACKEND URL của 1 Service
# ==============================================================================
task_change_backend() {
    echo -e "\n${YELLOW}[TÁC VỤ: ĐỔI BACKEND URL CỦA SERVICE]${NC}"
    echo -e "${GREEN}» Services hiện có:${NC}"
    list_names /services
    read -p "Nhập TÊN SERVICE cần đổi backend: " SNAME
    [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }
    read -p "Nhập URL BACKEND MỚI (Ví dụ: http://107.118.109.33:8000): " NEW_URL
    [ -z "$NEW_URL" ] && { echo -e "${RED}Bỏ qua: chưa nhập URL.${NC}"; return; }

    # PATCH với 'url' để Kong tự tách protocol/host/port/path
    curl -s -o /dev/null -w "   - Cập nhật backend: %{http_code}\n" -X PATCH ${KONG_ADMIN}/services/${SNAME} --data url="${NEW_URL}"
    echo -e "${GREEN}✔ Service [${SNAME}] đã trỏ sang ${NEW_URL}.${NC}"
}

# ==============================================================================
# TÁC VỤ 8: THÊM ROUTE cho 1 Service có sẵn
# ==============================================================================
task_add_route() {
    echo -e "\n${YELLOW}[TÁC VỤ: THÊM ROUTE CHO SERVICE CÓ SẴN]${NC}"
    echo -e "${GREEN}» Services hiện có:${NC}"
    list_names /services
    read -p "Nhập TÊN SERVICE: " SNAME
    [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }
    read -p "Nhập TÊN ROUTE MỚI (Ví dụ: vllm06-extra-route): " ROUTE_NAME
    read -p "Nhập ĐƯỜNG DẪN PATH MỚI (Ví dụ: /vllm06-extra): " ROUTE_PATH

    curl -s -o /dev/null -w "   - Tạo Route: %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SNAME}/routes --data name="${ROUTE_NAME}" --data paths[]="${ROUTE_PATH}" --data strip_path=true
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}✔ Đã thêm Route [${ROUTE_NAME}] → http://${SERVER_IP}:8000${ROUTE_PATH}/v1${NC}"
}

# ==============================================================================
# TÁC VỤ 9: BẬT RATE-LIMITING cho 1 Service
# ==============================================================================
task_rate_limit() {
    echo -e "\n${YELLOW}[TÁC VỤ: BẬT RATE-LIMITING CHO SERVICE]${NC}"
    echo -e "${GREEN}» Services hiện có:${NC}"
    list_names /services
    read -p "Nhập TÊN SERVICE: " SNAME
    [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên.${NC}"; return; }
    read -p "Giới hạn số request / PHÚT (để trống = bỏ qua): " R_MIN
    read -p "Giới hạn số request / GIỜ (để trống = bỏ qua): " R_HOUR

    DATA="name=rate-limiting"
    [ ! -z "$R_MIN" ]  && DATA="${DATA}&config.minute=${R_MIN}"
    [ ! -z "$R_HOUR" ] && DATA="${DATA}&config.hour=${R_HOUR}"
    # policy=local: đếm ngay trong node (phù hợp cụm Kong 1 node air-gap)
    DATA="${DATA}&config.policy=local"

    curl -s -o /dev/null -w "   - Bật rate-limiting: %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SNAME}/plugins --data "${DATA}"
    echo -e "${GREEN}✔ Đã bật rate-limiting cho [${SNAME}] (minute=${R_MIN:-∞}, hour=${R_HOUR:-∞}).${NC}"
}

# ==============================================================================
# TÁC VỤ 10: TẠO SERVICE MỚI — GẮN VÀO ACL/CONSUMER ĐÃ CÓ
#   Backend mới dùng chung key cũ: chỉ tạo Service + Route + bật key-auth/acl
#   trỏ vào ACL group sẵn có. KHÔNG tạo consumer/key mới.
# ==============================================================================
task_create_service_existing() {
    echo -e "\n${GREEN}[TÁC VỤ: TẠO SERVICE MỚI — GẮN ACL/CONSUMER ĐÃ CÓ]${NC}"
    echo "» Các nhóm ACL đang tồn tại:"
    curl -s "${KONG_ADMIN}/acls" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
gs=sorted({x.get('group') for x in d if x.get('group')})
for g in gs:
    print('   -', g)
if not gs:
    print('   (chưa có nhóm ACL nào — hãy dùng option 1 để tạo mới trước)')" 2>/dev/null

    echo -e "\nChọn định dạng Header mà các consumer trong nhóm này đang dùng:"
    echo "1) x-api-key (Kiểu N8N)"
    echo "2) Authorization + Bearer (Kiểu Dify)"
    read -p "Lựa chọn (1 hoặc 2): " APP_TYPE
    if [ "$APP_TYPE" == "2" ]; then
        HEADER_TYPE="Authorization"
    else
        HEADER_TYPE="x-api-key"
    fi

    echo -e "\n👉 VUI LÒNG NHẬP THÔNG TIN:"
    read -p "➔ Nhập URL VLLM BACKEND MỚI (Ví dụ: http://107.118.109.33:8000): " VLLM_BACKEND
    read -p "1. Nhập TÊN SERVICE MỚI (Ví dụ: vllm-coder-service): " SERVICE_NAME
    read -p "2. Nhập TÊN ROUTE MỚI (Ví dụ: vllm-coder-route): " ROUTE_NAME
    read -p "3. Nhập ĐƯỜNG DẪN PATH MỚI (Ví dụ: /coder): " ROUTE_PATH
    read -p "4. Nhập TÊN NHÓM ACL ĐÃ CÓ để cấp quyền (copy từ danh sách trên): " ACL_GROUP
    read -p "5. Nhập IP ĐƯỢC PHÉP TRUY CẬP (Để trống nếu mở Public): " ALLOWED_IPS

    [ -z "$SERVICE_NAME" ] && { echo -e "${RED}Bỏ qua: chưa nhập tên service.${NC}"; return; }
    [ -z "$ACL_GROUP" ] && { echo -e "${RED}Bỏ qua: chưa nhập nhóm ACL.${NC}"; return; }

    echo -e "\n🚀 Đang tạo Service mới gắn vào ACL [${ACL_GROUP}]..."
    curl -s -o /dev/null -w "   - Khởi tạo Service: %{http_code}\n" -X POST ${KONG_ADMIN}/services --data name="${SERVICE_NAME}" --data url="${VLLM_BACKEND}" --data connect_timeout=60000 --data read_timeout=600000 --data write_timeout=600000
    curl -s -o /dev/null -w "   - Khởi tạo Route: %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/routes --data name="${ROUTE_NAME}" --data paths[]="${ROUTE_PATH}" --data strip_path=true
    curl -s -o /dev/null -w "   - Kích hoạt lớp 1 (Key-Auth): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=key-auth --data config.key_names="${HEADER_TYPE}"
    curl -s -o /dev/null -w "   - Kích hoạt lớp 2 (ACL Whitelist [${ACL_GROUP}]): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=acl --data config.allow="${ACL_GROUP}"
    if [ ! -z "${ALLOWED_IPS}" ]; then
        curl -s -o /dev/null -w "   - Kích hoạt lớp 3 (IP Restriction): %{http_code}\n" -X POST ${KONG_ADMIN}/services/${SERVICE_NAME}/plugins --data name=ip-restriction --data config.allow="${ALLOWED_IPS}"
    fi

    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}✔ HOÀN THÀNH: Service mới đã dùng chung consumer/key của nhóm ACL [${ACL_GROUP}].${NC}"
    echo "• API URL: http://${SERVER_IP}:8000${ROUTE_PATH}/v1"
    echo "• Các app thuộc nhóm [${ACL_GROUP}] gọi được NGAY bằng key cũ (không cần cấp key mới)."
}

# ==============================================================================
# TÁC VỤ 11: TEST / HEALTH-CHECK 1 ROUTE (qua cổng proxy 8000)
# ==============================================================================
task_test_route() {
    echo -e "\n${CYAN}[TÁC VỤ: TEST / HEALTH-CHECK 1 ROUTE]${NC}"
    echo -e "${GREEN}» Routes hiện có:${NC}"
    curl -s "${KONG_ADMIN}/routes" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for r in d:
    print('   -', r.get('name'), 'paths=', r.get('paths'))" 2>/dev/null

    read -p "Nhập PROXY host:port [mặc định localhost:8000]: " PROXY
    PROXY=${PROXY:-localhost:8000}
    read -p "Nhập PATH của route cần test (Ví dụ: /coder): " TPATH
    [ -z "$TPATH" ] && { echo -e "${RED}Bỏ qua: chưa nhập path.${NC}"; return; }
    read -p "Nhập API KEY để test (để trống nếu route không bảo mật): " TKEY

    HDR=()
    if [ ! -z "$TKEY" ]; then
        echo "Header key kiểu: 1) x-api-key   2) Authorization + Bearer"
        read -p "Lựa chọn (1 hoặc 2): " HT
        if [ "$HT" == "2" ]; then
            HDR=(-H "Authorization: Bearer ${TKEY}")
        else
            HDR=(-H "x-api-key: ${TKEY}")
        fi
    fi

    URL="http://${PROXY}${TPATH}/v1/models"
    echo -e "\n🌐 GET ${URL}"
    CODE=$(curl -s -o /tmp/kong_test_body.$$ -w "%{http_code}" --max-time 10 "${HDR[@]}" "$URL")
    echo -e "   → HTTP ${CODE}"
    echo "   → Body (rút gọn):"
    head -c 400 /tmp/kong_test_body.$$ 2>/dev/null; echo
    rm -f /tmp/kong_test_body.$$

    case "$CODE" in
        200)     echo -e "${GREEN}✔ Route sống & xác thực OK.${NC}" ;;
        401|403) echo -e "${RED}✘ Bị chặn (key/ACL/IP sai) — HTTP ${CODE}.${NC}" ;;
        404)     echo -e "${RED}✘ Không thấy route/path — HTTP 404.${NC}" ;;
        000)     echo -e "${RED}✘ Không kết nối được tới ${PROXY}.${NC}" ;;
        *)       echo -e "${YELLOW}HTTP ${CODE} — kiểm tra backend.${NC}" ;;
    esac
}

# ==============================================================================
# TÁC VỤ 12: BACKUP / EXPORT TOÀN BỘ CẤU HÌNH RA FILE JSON
# ==============================================================================
task_backup() {
    echo -e "\n${CYAN}[TÁC VỤ: BACKUP / EXPORT CẤU HÌNH]${NC}"
    TS=$(date +%Y%m%d-%H%M%S)
    OUT="$(pwd)/kong-backup-${TS}.json"

    {
        echo "{"
        echo "  \"exported_at\": \"${TS}\","
        echo "  \"services\": $(curl -s ${KONG_ADMIN}/services),"
        echo "  \"routes\": $(curl -s ${KONG_ADMIN}/routes),"
        echo "  \"consumers\": $(curl -s ${KONG_ADMIN}/consumers),"
        echo "  \"plugins\": $(curl -s ${KONG_ADMIN}/plugins),"
        echo "  \"acls\": $(curl -s ${KONG_ADMIN}/acls),"
        echo "  \"key_auths\": $(curl -s ${KONG_ADMIN}/key-auths)"
        echo "}"
    } > "$OUT"

    if python3 -m json.tool "$OUT" > /dev/null 2>&1; then
        SZ=$(wc -c < "$OUT")
        echo -e "${GREEN}✔ Đã backup: ${OUT} (${SZ} bytes)${NC}"
        echo -e "${YELLOW}⚠ File chứa cả API key (key_auths) — hãy giữ bảo mật / xóa sau khi dùng.${NC}"
    else
        echo -e "${RED}✘ Backup lỗi (JSON không hợp lệ). Kiểm tra kết nối Admin API.${NC}"
        rm -f "$OUT"
    fi
}

# ==============================================================================
# TÁC VỤ 13: SỬA (PATCH) PLUGIN ĐÃ CÓ — rate-limiting / ip-restriction
#   (Vá lỗi trùng: đổi giới hạn PHẢI patch plugin cũ, không POST tạo mới)
# ==============================================================================
task_edit_plugin() {
    echo -e "\n${YELLOW}[TÁC VỤ: SỬA PLUGIN ĐÃ CÓ]${NC}"
    echo -e "${GREEN}» Services hiện có:${NC}"
    list_names /services
    read -p "Nhập TÊN SERVICE: " SNAME
    [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua.${NC}"; return; }

    echo -e "${GREEN}» Plugins của [${SNAME}]:${NC}"
    curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print('   -', x.get('name'))" 2>/dev/null
    read -p "Nhập TÊN PLUGIN cần sửa (rate-limiting / ip-restriction): " PNAME

    PID=$(curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    if x.get('name')=='${PNAME}':
        print(x.get('id')); break" 2>/dev/null)
    [ -z "$PID" ] && { echo -e "${RED}Không tìm thấy plugin [${PNAME}] trên service này.${NC}"; return; }

    if [ "$PNAME" == "rate-limiting" ]; then
        read -p "Giới hạn / PHÚT (để trống = giữ nguyên): " R_MIN
        read -p "Giới hạn / GIỜ (để trống = giữ nguyên): " R_HOUR
        DATA=""
        [ ! -z "$R_MIN" ]  && DATA="config.minute=${R_MIN}"
        [ ! -z "$R_HOUR" ] && DATA="${DATA}${DATA:+&}config.hour=${R_HOUR}"
        [ -z "$DATA" ] && { echo -e "${YELLOW}Không có gì để đổi.${NC}"; return; }
        curl -s -o /dev/null -w "   - Cập nhật rate-limiting: %{http_code}\n" -X PATCH ${KONG_ADMIN}/plugins/${PID} --data "${DATA}"
    elif [ "$PNAME" == "ip-restriction" ]; then
        read -p "IP cho phép MỚI (Ví dụ: 107.118.99.200): " IPS
        [ -z "$IPS" ] && { echo -e "${YELLOW}Không có gì để đổi.${NC}"; return; }
        curl -s -o /dev/null -w "   - Cập nhật ip-restriction: %{http_code}\n" -X PATCH ${KONG_ADMIN}/plugins/${PID} --data config.allow="${IPS}"
    else
        echo -e "${RED}Chỉ hỗ trợ sửa nhanh 'rate-limiting' hoặc 'ip-restriction'.${NC}"
        return
    fi
    echo -e "${GREEN}✔ Đã cập nhật plugin [${PNAME}] của [${SNAME}].${NC}"
}

# ==============================================================================
# TÁC VỤ 14: XÓA LẺ 1 ROUTE / 1 PLUGIN
# ==============================================================================
task_delete_single() {
    echo -e "\n${RED}[TÁC VỤ: XÓA LẺ 1 ROUTE / 1 PLUGIN]${NC}"
    echo "1) Xóa 1 ROUTE"
    echo "2) Xóa 1 PLUGIN của 1 service"
    read -p "Lựa chọn (1 hoặc 2): " X

    if [ "$X" == "1" ]; then
        echo -e "${GREEN}» Routes hiện có:${NC}"
        list_names /routes
        read -p "Nhập TÊN ROUTE cần xóa: " RNAME
        [ -z "$RNAME" ] && { echo -e "${RED}Bỏ qua.${NC}"; return; }
        curl -s -o /dev/null -w "   - Xóa Route ${RNAME}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/routes/${RNAME}"
        echo -e "${GREEN}✔ Đã xóa Route [${RNAME}].${NC}"

    elif [ "$X" == "2" ]; then
        echo -e "${GREEN}» Services hiện có:${NC}"
        list_names /services
        read -p "Nhập TÊN SERVICE: " SNAME
        [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua.${NC}"; return; }
        echo -e "${GREEN}» Plugins của [${SNAME}]:${NC}"
        curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print('   -', x.get('name'), '(id:', x.get('id'), ')')" 2>/dev/null
        read -p "Nhập TÊN PLUGIN cần xóa: " PNAME
        PID=$(curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    if x.get('name')=='${PNAME}':
        print(x.get('id')); break" 2>/dev/null)
        [ -z "$PID" ] && { echo -e "${RED}Không tìm thấy plugin.${NC}"; return; }
        curl -s -o /dev/null -w "   - Xóa Plugin ${PNAME}: %{http_code}\n" -X DELETE "${KONG_ADMIN}/plugins/${PID}"
        echo -e "${GREEN}✔ Đã xóa Plugin [${PNAME}] khỏi [${SNAME}].${NC}"
    else
        echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
    fi
}

# ==============================================================================
# TÁC VỤ 15: BẬT / TẮT TẠM 1 PLUGIN (enabled=true/false, không xóa)
# ==============================================================================
task_toggle_plugin() {
    echo -e "\n${YELLOW}[TÁC VỤ: BẬT / TẮT TẠM 1 PLUGIN]${NC}"
    echo -e "${GREEN}» Services hiện có:${NC}"
    list_names /services
    read -p "Nhập TÊN SERVICE: " SNAME
    [ -z "$SNAME" ] && { echo -e "${RED}Bỏ qua.${NC}"; return; }

    echo -e "${GREEN}» Plugins của [${SNAME}] (name | enabled):${NC}"
    curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    print('   -', x.get('name'), '| enabled:', x.get('enabled'))" 2>/dev/null
    read -p "Nhập TÊN PLUGIN: " PNAME

    PID=$(curl -s "${KONG_ADMIN}/services/${SNAME}/plugins" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
for x in d:
    if x.get('name')=='${PNAME}':
        print(x.get('id')); break" 2>/dev/null)
    [ -z "$PID" ] && { echo -e "${RED}Không tìm thấy plugin.${NC}"; return; }

    echo "1) BẬT (enabled=true)    2) TẮT (enabled=false)"
    read -p "Lựa chọn (1 hoặc 2): " T
    if [ "$T" == "2" ]; then VAL=false; else VAL=true; fi
    curl -s -o /dev/null -w "   - Đặt enabled=${VAL}: %{http_code}\n" -X PATCH ${KONG_ADMIN}/plugins/${PID} --data enabled=${VAL}
    echo -e "${GREEN}✔ Plugin [${PNAME}] của [${SNAME}] giờ enabled=${VAL}.${NC}"
}

# ==============================================================================
# TÁC VỤ 16: XEM API KEY THẬT CỦA 1 CONSUMER (nhạy cảm)
# ==============================================================================
task_show_keys() {
    echo -e "\n${YELLOW}[TÁC VỤ: XEM API KEY THẬT CỦA 1 CONSUMER]${NC}"
    echo -e "${RED}⚠ Thông tin nhạy cảm — chỉ xem khi thực sự cần.${NC}"
    echo -e "${GREEN}» Consumers hiện có:${NC}"
    list_names /consumers
    read -p "Nhập TÊN CONSUMER: " CNAME
    [ -z "$CNAME" ] && { echo -e "${RED}Bỏ qua.${NC}"; return; }

    echo -e "${GREEN}» API key của [${CNAME}]:${NC}"
    curl -s "${KONG_ADMIN}/consumers/${CNAME}/key-auth" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin).get('data',[])
except Exception:
    d=[]
if not d:
    print('   (không có key)')
for x in d:
    print('   -', x.get('key'))" 2>/dev/null
}

# ==============================================================================
# TÁC VỤ 17: RESTORE — dựng lại cấu hình từ file backup của tác vụ 12
#   Dùng PUT theo id (upsert) → giữ nguyên id, key, ACL group, foreign key.
#   Thứ tự phụ thuộc: services → consumers → routes → key-auth/acl → plugins
# ==============================================================================
task_restore() {
    echo -e "\n${CYAN}[TÁC VỤ: RESTORE CẤU HÌNH TỪ FILE BACKUP]${NC}"
    read -p "Nhập ĐƯỜNG DẪN file backup (.json): " FILE
    [ ! -f "$FILE" ] && { echo -e "${RED}Không thấy file: ${FILE}${NC}"; return; }
    if ! python3 -m json.tool "$FILE" > /dev/null 2>&1; then
        echo -e "${RED}File không phải JSON hợp lệ.${NC}"; return
    fi

    echo -e "${RED}⚠ Sẽ GHI ĐÈ cấu hình Kong theo nội dung file (PUT theo id).${NC}"
    read -p "Gõ 'YES' để xác nhận: " CONF
    [ "$CONF" != "YES" ] && { echo -e "${YELLOW}Đã hủy.${NC}"; return; }

    TMP="/tmp/kong_restore.$$"
    python3 - "$FILE" > "$TMP" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))
def coll(name):
    return b.get(name, {}).get('data', []) or []
out = []
def emit(url, obj):
    out.append(url + "\t" + json.dumps(obj, ensure_ascii=False))
for s in coll('services'):
    emit('/services/' + s['id'], s)
for c in coll('consumers'):
    emit('/consumers/' + c['id'], c)
for r in coll('routes'):
    emit('/routes/' + r['id'], r)
# Credential: chỉ gửi field cốt lõi (id giữ qua URL). Gửi full body sẽ khiến
# Kong trả 500 vì các field consumer/ttl/created_at.
for k in coll('key_auths'):
    cid = (k.get('consumer') or {}).get('id')
    if cid:
        emit('/consumers/%s/key-auth/%s' % (cid, k['id']), {'key': k.get('key')})
for a in coll('acls'):
    cid = (a.get('consumer') or {}).get('id')
    if cid:
        emit('/consumers/%s/acls/%s' % (cid, a['id']), {'group': a.get('group')})
for p in coll('plugins'):
    emit('/plugins/' + p['id'], p)
sys.stdout.write("\n".join(out))
PYEOF

    echo -e "\n🚀 Đang khôi phục..."
    OK=0; FAIL=0
    while IFS=$'\t' read -r URL BODY; do
        [ -z "$URL" ] && continue
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${KONG_ADMIN}${URL}" -H "Content-Type: application/json" -d "${BODY}")
        echo "   PUT ${URL} -> ${CODE}"
        if [ "${CODE:0:1}" == "2" ]; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi
    done < "$TMP"
    rm -f "$TMP"
    echo -e "\n${GREEN}✔ Khôi phục xong: ${OK} OK / ${FAIL} lỗi. Chạy option 3 (Tổng quan) để kiểm tra.${NC}"
}

# ==============================================================================
# VÒNG LẶP MENU CHÍNH
# ==============================================================================
while true; do
    clear
    echo -e "${CYAN}============================================================"
    echo "          HỆ THỐNG QUẢN LÝ KONG GATEWAY CHO VLLM"
    echo -e "===========================================================${NC}"
    echo "Mời bạn chọn tác vụ muốn thực hiện:"
    echo -e "1) ${GREEN}TẠO MỚI TOÀN BỘ${NC} (Service + Route + Consumer + Bảo mật 3 lớp)"
    echo -e "2) ${YELLOW}THÊM CONSUMER MỚI${NC} (Chỉ thêm App/Key mới vào Service/ACL đã có sẵn)"
    echo -e "3) ${CYAN}TỔNG QUAN${NC} toàn bộ cấu hình hiện tại (Service→Route→Plugin + Consumer)"
    echo -e "4) ${CYAN}LIỆT KÊ NHANH${NC} 1 nhóm (Services / Routes / Consumers / Plugins)"
    echo -e "5) ${RED}XÓA${NC} (Service kèm Route+Plugin, hoặc Consumer)"
    echo -e "6) ${YELLOW}THU HỒI / ĐỔI API KEY${NC} của 1 Consumer"
    echo -e "7) ${YELLOW}ĐỔI BACKEND URL${NC} của 1 Service"
    echo -e "8) ${GREEN}THÊM ROUTE${NC} cho 1 Service có sẵn"
    echo -e "9) ${YELLOW}BẬT RATE-LIMITING${NC} cho 1 Service"
    echo -e "10) ${GREEN}TẠO SERVICE MỚI${NC} gắn vào ACL/consumer ĐÃ CÓ (backend mới, dùng key cũ)"
    echo -e "${CYAN}---------------- TIỆN ÍCH / BẢO TRÌ ----------------${NC}"
    echo -e "11) ${CYAN}TEST${NC} 1 route (health-check qua cổng 8000)"
    echo -e "12) ${CYAN}BACKUP${NC} toàn bộ cấu hình ra file JSON (dùng 17 để RESTORE)"
    echo -e "13) ${YELLOW}SỬA PLUGIN${NC} đã có (rate-limit / IP whitelist)"
    echo -e "14) ${RED}XÓA LẺ${NC} 1 Route / 1 Plugin"
    echo -e "15) ${YELLOW}BẬT/TẮT${NC} tạm 1 Plugin"
    echo -e "16) ${YELLOW}XEM API KEY${NC} thật của 1 Consumer"
    echo -e "17) ${CYAN}RESTORE${NC} cấu hình từ file backup (.json)"
    echo "18) Thoát"
    echo "------------------------------------------------------------"
    read -p "Nhập lựa chọn của bạn (1-18): " MAIN_CHOICE || { echo; exit 0; }

    case "$MAIN_CHOICE" in
        1) task_create_full ;;
        2) task_add_consumer ;;
        3) task_overview ;;
        4) task_list ;;
        5) task_delete ;;
        6) task_rotate_key ;;
        7) task_change_backend ;;
        8) task_add_route ;;
        9) task_rate_limit ;;
        10) task_create_service_existing ;;
        11) task_test_route ;;
        12) task_backup ;;
        13) task_edit_plugin ;;
        14) task_delete_single ;;
        15) task_toggle_plugin ;;
        16) task_show_keys ;;
        17) task_restore ;;
        18) echo "Tạm biệt!"; exit 0 ;;
        *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}" ;;
    esac

    echo ""
    read -p "↩  Nhấn ENTER để quay lại menu..."
done

#!/bin/bash

# Конфигурационные переменные
CONFIG_DIR="/etc/traefik"
DYNAMIC_CONFIG_DIR="$CONFIG_DIR/conf.d"
TRAEFIK_CONTAINER_NAME="traefik"
TRAEFIK_NAMESPACE="traefik"  # Для Kubernetes
REQUIRED_PACKAGES=("jq" "docker")  # Базовые обязательные пакеты
K8S_PACKAGES=("kubectl")      # Пакеты для Kubernetes
LOG_FILE="/var/log/traefik-manager.log"
BACKUP_DIR="/opt/traefik-backups"
VERSION="1.3.0"
TEMP_FILES=() # Для отслеживания временных файлов
K8S_ENABLED=false # Флаг наличия Kubernetes

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Вспомогательные функции ---

# Функция логирования
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Функция очистки временных файлов
cleanup() {
    echo -e "\n${BLUE}Завершение работы скрипта...${NC}"
    
    # Удаление временных файлов
    for temp_file in "${TEMP_FILES[@]}"; do
        if [ -f "$temp_file" ]; then
            log "INFO" "Удаление временного файла: $temp_file"
            rm -f "$temp_file"
        fi
    done
    
    exit 0
}

# Регистрация обработчиков сигналов
trap cleanup SIGINT SIGTERM EXIT

# Проверка доступной оперативной памяти
check_memory() {
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$mem_total" -lt 2048 ]; then
        return 1  # Недостаточно памяти
    else
        return 0  # Достаточно памяти
    fi
}

# Проверка наличия Kubernetes
check_kubernetes() {
    log "INFO" "Проверка наличия Kubernetes"
    echo -e "${BLUE}Проверка наличия Kubernetes...${NC}"
    
    # Проверяем наличие minikube или kind
    if command -v minikube &> /dev/null || command -v kind &> /dev/null; then
        if command -v minikube &> /dev/null; then
            if minikube status &> /dev/null; then
                log "INFO" "Minikube найден и запущен"
                echo -e "${GREEN}Minikube найден и запущен.${NC}"
                K8S_ENABLED=true
                return 0
            else
                log "WARNING" "Minikube найден, но не запущен"
                echo -e "${YELLOW}Minikube найден, но не запущен.${NC}"
                read -p "Запустить minikube? (y/n): " start_answer
                if [ "$start_answer" = "y" ]; then
                    minikube start
                    if [ $? -eq 0 ]; then
                        log "INFO" "Minikube успешно запущен"
                        echo -e "${GREEN}Minikube успешно запущен.${NC}"
                        K8S_ENABLED=true
                        return 0
                    else
                        log "ERROR" "Не удалось запустить minikube"
                        echo -e "${RED}Не удалось запустить minikube.${NC}"
                        return 1
                    fi
                fi
            fi
        fi
        
        if command -v kind &> /dev/null; then
            if kind get clusters &> /dev/null && [ "$(kind get clusters | wc -l)" -gt 0 ]; then
                log "INFO" "Kind кластер найден"
                echo -e "${GREEN}Kind кластер найден.${NC}"
                K8S_ENABLED=true
                return 0
            else
                log "WARNING" "Kind найден, но кластеры не созданы"
                echo -e "${YELLOW}Kind найден, но кластеры не созданы.${NC}"
                read -p "Создать кластер kind? (y/n): " create_answer
                if [ "$create_answer" = "y" ]; then
                    kind create cluster --name traefik-cluster
                    if [ $? -eq 0 ]; then
                        log "INFO" "Kind кластер успешно создан"
                        echo -e "${GREEN}Kind кластер успешно создан.${NC}"
                        K8S_ENABLED=true
                        return 0
                    else
                        log "ERROR" "Не удалось создать kind кластер"
                        echo -e "${RED}Не удалось создать kind кластер.${NC}"
                        return 1
                    fi
                fi
            fi
        fi
    fi
    
    # Проверяем, существует ли полноценный кластер Kubernetes
    if command -v kubectl &> /dev/null; then
        if kubectl cluster-info &> /dev/null; then
            log "INFO" "Kubernetes кластер найден и доступен"
            echo -e "${GREEN}Kubernetes кластер найден и доступен.${NC}"
            K8S_ENABLED=true
            return 0
        fi
    fi
    
    return 1
}

# Установка Kubernetes (minikube)
install_kubernetes() {
    log "INFO" "Установка Kubernetes (minikube)"
    echo -e "${BLUE}Установка Kubernetes (minikube)...${NC}"
    
    # Проверка памяти
    if ! check_memory; then
        log "WARNING" "Недостаточно оперативной памяти для Kubernetes (минимум 2GB)"
        echo -e "${RED}Внимание! Для работы Kubernetes требуется минимум 2GB оперативной памяти!${NC}"
        local mem_total=$(free -m | awk '/^Mem:/{print $2}')
        echo -e "${YELLOW}Доступно: ${mem_total} MB${NC}"
        read -p "Продолжить установку несмотря на недостаток памяти? (y/n): " continue_answer
        if [ "$continue_answer" != "y" ]; then
            log "INFO" "Пользователь отменил установку Kubernetes из-за недостатка памяти"
            echo -e "${YELLOW}Установка Kubernetes отменена.${NC}"
            return 1
        fi
    fi
    
    # Определение ОС
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS_TYPE=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    else
        OS_TYPE="unknown"
    fi
    
    # Установка kubectl
    log "INFO" "Установка kubectl"
    echo -e "${GREEN}Устанавливаю kubectl...${NC}"
                        
    # Определение архитектуры
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH_FLAG="amd64" ;;
        aarch64) ARCH_FLAG="arm64" ;;
        *) ARCH_FLAG="amd64" ;;
    esac
                        
    # Получение последней стабильной версии
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    log "INFO" "Устанавливается версия kubectl: $KUBECTL_VERSION для архитектуры $ARCH_FLAG"
                        
    # Загрузка и установка kubectl
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_FLAG}/kubectl" && \
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_FLAG}/kubectl.sha256" && \
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check && \
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm -f kubectl kubectl.sha256 || {
        log "ERROR" "Ошибка установки kubectl"
        echo -e "${RED}Ошибка установки kubectl!${NC}"
        return 1
    }
    
    # Установка minikube
    log "INFO" "Установка minikube"
    echo -e "${GREEN}Устанавливаю minikube...${NC}"
    
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH_FLAG} && \
    sudo install minikube-linux-${ARCH_FLAG} /usr/local/bin/minikube && \
    rm -f minikube-linux-${ARCH_FLAG} || {
        log "ERROR" "Ошибка установки minikube"
        echo -e "${RED}Ошибка установки minikube!${NC}"
        return 1
    }
    
    # Запуск minikube
    log "INFO" "Запуск minikube"
    echo -e "${GREEN}Запускаю minikube...${NC}"
    
    # Определение драйвера
    if command -v docker &> /dev/null; then
        minikube start --driver=docker
    else
        minikube start
    fi
    
    if [ $? -eq 0 ]; then
        log "INFO" "Minikube успешно запущен"
        echo -e "${GREEN}Minikube успешно запущен.${NC}"
        K8S_ENABLED=true
        return 0
    else
        log "ERROR" "Не удалось запустить minikube"
        echo -e "${RED}Не удалось запустить minikube.${NC}"
        return 1
    fi
}

# Проверка и установка зависимостей
install_dependencies() {
    log "INFO" "Проверка зависимостей"
    echo -e "${YELLOW}Проверка зависимостей...${NC}"
    
    # Определение дистрибутива
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS_TYPE=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    else
        OS_TYPE="unknown"
    fi
    
    log "INFO" "Определен дистрибутив: $OS_TYPE"
    echo -e "${BLUE}Определен дистрибутив: $OS_TYPE${NC}"
    
    # Сначала установим основные пакеты
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            log "WARNING" "$pkg не установлен"
            echo -e "${RED}Ошибка: $pkg не установлен!${NC}"
            read -p "Установить автоматически? (y/n): " answer
            if [ "$answer" = "y" ]; then
                case "$pkg" in
                    "jq")
                        echo -e "${GREEN}Устанавливаю jq...${NC}"
                        case $OS_TYPE in
                            "ubuntu"|"debian")
                                sudo apt update && sudo apt install -y jq
                                ;;
                            "centos"|"rhel"|"fedora")
                                sudo yum install -y jq
                                ;;
                            *)
                                echo -e "${YELLOW}Не удалось определить дистрибутив. Используем apt...${NC}"
                                sudo apt update && sudo apt install -y jq
                                ;;
                        esac || {
                            log "ERROR" "Ошибка установки jq"
                            echo -e "${RED}Ошибка установки jq!${NC}"
                            exit 1
                        }
                        ;;
                    "docker")
                        log "INFO" "Установка Docker"
                        echo -e "${GREEN}Устанавливаю Docker...${NC}"
                        curl -fsSL https://get.docker.com | sh || {
                            log "ERROR" "Ошибка установки Docker"
                            echo -e "${RED}Ошибка установки Docker!${NC}"
                            exit 1
                        }
                        sudo usermod -aG docker "$USER"
                        log "INFO" "Пользователь $USER добавлен в группу docker"
                        ;;
                esac
                log "INFO" "$pkg успешно установлен"
                echo -e "${GREEN}$pkg успешно установлен.${NC}"
            else
                log "ERROR" "Прерывание: $pkg обязателен для работы скрипта"
                echo -e "${RED}Прерывание: $pkg обязателен для работы скрипта.${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}$pkg установлен.${NC}"
        fi
    done
    
    # Проверка наличия Kubernetes
    if ! check_kubernetes; then
        log "WARNING" "Kubernetes не найден или не запущен"
        echo -e "${YELLOW}Kubernetes не найден или не запущен.${NC}"
        echo -e "${YELLOW}Некоторые функции будут недоступны без Kubernetes.${NC}"
        
        read -p "Установить Kubernetes (minikube)? (y/n): " k8s_answer
        if [ "$k8s_answer" = "y" ]; then
            install_kubernetes
            if [ $? -eq 0 ]; then
                # Если Kubernetes установлен успешно, установим дополнительные пакеты
                for pkg in "${K8S_PACKAGES[@]}"; do
                    if ! command -v "$pkg" &> /dev/null; then
                        case "$pkg" in
                            "kubectl")
                                # Kubectl уже должен быть установлен через install_kubernetes
                                ;;
                        esac
                    else
                        echo -e "${GREEN}$pkg установлен.${NC}"
                    fi
                done
            else
                echo -e "${YELLOW}Продолжение без Kubernetes. Некоторые функции будут недоступны.${NC}"
                K8S_ENABLED=false
            fi
        else
            log "INFO" "Пользователь отказался от установки Kubernetes"
            echo -e "${YELLOW}Продолжение без Kubernetes. Некоторые функции будут недоступны.${NC}"
            K8S_ENABLED=false
        fi
    else
        K8S_ENABLED=true
        # Если Kubernetes уже установлен, проверим наличие kubectl
        if ! command -v kubectl &> /dev/null; then
            log "WARNING" "kubectl не установлен"
            echo -e "${YELLOW}kubectl не установлен, хотя Kubernetes запущен.${NC}"
            read -p "Установить kubectl? (y/n): " kubectl_answer
            if [ "$kubectl_answer" = "y" ]; then
                log "INFO" "Установка kubectl"
                echo -e "${GREEN}Устанавливаю kubectl...${NC}"
                
                # Определение архитектуры
                ARCH=$(uname -m)
                case $ARCH in
                    x86_64) ARCH_FLAG="amd64" ;;
                    aarch64) ARCH_FLAG="arm64" ;;
                    *) ARCH_FLAG="amd64" ;;
                esac
                
                # Получение последней стабильной версии
                KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
                log "INFO" "Устанавливается версия kubectl: $KUBECTL_VERSION для архитектуры $ARCH_FLAG"
                
                # Загрузка и установка
                curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_FLAG}/kubectl" && \
                curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_FLAG}/kubectl.sha256" && \
                echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check && \
                sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
                rm -f kubectl kubectl.sha256 || {
                    log "ERROR" "Ошибка установки kubectl"
                    echo -e "${RED}Ошибка установки kubectl!${NC}"
                    K8S_ENABLED=false
                }
            else
                log "INFO" "Пользователь отказался от установки kubectl"
                echo -e "${YELLOW}Без kubectl некоторые функции Kubernetes будут недоступны.${NC}"
                K8S_ENABLED=false
            fi
        fi
    fi
}

# Проверка подключения к Kubernetes
check_k8s_connection() {
    # Если Kubernetes отключен, сразу возвращаем ошибку
    if [ "$K8S_ENABLED" = false ]; then
        log "WARNING" "Kubernetes не включен в системе"
        echo -e "${YELLOW}Kubernetes не включен в системе.${NC}"
        return 1
    fi
    
    log "INFO" "Проверка подключения к Kubernetes"
    if ! kubectl cluster-info &> /dev/null; then
        log "ERROR" "Ошибка подключения к Kubernetes"
        echo -e "${RED}Ошибка подключения к Kubernetes!${NC}"
        echo "Убедитесь что:"
        echo "1. kubectl настроен правильно"
        echo "2. KUBECONFIG указан или конфиг в ~/.kube/config"
        
        read -p "Настроить KUBECONFIG? (y/n): " setup_answer
        if [ "$setup_answer" = "y" ]; then
            read -p "Укажите путь к файлу kubeconfig: " kubeconfig_path
            if [ -f "$kubeconfig_path" ]; then
                export KUBECONFIG="$kubeconfig_path"
                log "INFO" "KUBECONFIG установлен: $KUBECONFIG"
                echo -e "${GREEN}KUBECONFIG установлен. Повторная проверка...${NC}"
                if ! kubectl cluster-info &> /dev/null; then
                    log "ERROR" "Подключение не установлено после настройки KUBECONFIG"
                    echo -e "${RED}Подключение все равно не установлено.${NC}"
                    return 1
                fi
                return 0
            else
                log "ERROR" "Файл kubeconfig не найден: $kubeconfig_path"
                echo -e "${RED}Файл не найден: $kubeconfig_path${NC}"
                return 1
            fi
        fi
        return 1
    fi
    log "INFO" "Подключение к Kubernetes установлено"
    return 0
}

# Управление IngressRoute (Traefik CRD)
manage_ingress_route() {
    log "INFO" "Запуск управления IngressRoute"
    check_k8s_connection || return

    echo -e "${BLUE}Доступные IngressRoute:${NC}"
    kubectl get ingressroute -A

    echo -e "
    ${YELLOW}1) Создать новый IngressRoute
    2) Редактировать существующий
    3) Удалить IngressRoute
    4) Вернуться в меню${NC}
    "
    read -p "Выберите действие: " action

    case $action in
        1)
            log "INFO" "Создание нового IngressRoute"
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}

            temp_file=$(mktemp)
            TEMP_FILES+=("$temp_file")
            
            cat <<EOF > "$temp_file"
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: $name
  namespace: $ns
spec:
  entryPoints:
    - web
  routes:
  - match: Host(\`example.com\`)
    kind: Rule
    services:
    - name: your-service
      port: 80
EOF
            nano "$temp_file"
            kubectl apply -f "$temp_file"
            log "INFO" "Создан IngressRoute: $name в namespace $ns"
            ;;
        2)
            log "INFO" "Редактирование IngressRoute"
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}
            kubectl edit ingressroute "$name" -n "$ns"
            log "INFO" "Отредактирован IngressRoute: $name в namespace $ns"
            ;;
        3)
            log "INFO" "Удаление IngressRoute"
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}
            read -p "Вы точно хотите удалить $name? (y/n): " confirm
            if [ "$confirm" = "y" ]; then
                kubectl delete ingressroute "$name" -n "$ns"
                log "INFO" "Удален IngressRoute: $name из namespace $ns"
            else
                echo -e "${YELLOW}Отмена операции${NC}"
            fi
            ;;
        4) 
            log "INFO" "Возврат в главное меню из управления IngressRoute"
            return ;;
        *) echo -e "${RED}Неверный вариант!${NC}" ;;
    esac
}

# Управление Docker-лейблами
manage_docker_labels() {
    log "INFO" "Запуск управления Docker-лейблами"
    echo -e "${BLUE}Список запущенных контейнеров:${NC}"
    docker ps --format "{{.Names}}"

    read -p "Введите имя контейнера: " container_name
    if ! docker inspect "$container_name" &> /dev/null; then
        log "ERROR" "Контейнер $container_name не найден"
        echo -e "${RED}Контейнер $container_name не найден!${NC}"
        return
    fi

    echo -e "${GREEN}Текущие лейблы контейнера:${NC}"
    docker inspect "$container_name" --format '{{json .Config.Labels}}' | jq

    echo -e "
    ${YELLOW}1) Добавить/изменить лейбл
    2) Удалить лейбл
    3) Показать рекомендуемые лейблы для Traefik
    4) Перезапустить контейнер
    5) Вернуться в меню${NC}
    "
    read -p "Выберите действие: " action

    case $action in
        1)
            read -p "Ключ лейбла (например, traefik.http.routers.myapp.rule): " key
            read -p "Значение лейбла (например, Host(\`example.com\`)): " value
            docker container update --label-add "$key=$value" "$container_name"
            log "INFO" "Добавлен лейбл $key=$value для контейнера $container_name"
            echo -e "${GREEN}Лейбл добавлен. Не забудьте перезапустить контейнер.${NC}"
            ;;
        2)
            read -p "Ключ лейбла для удаления: " key
            docker container update --label-rm "$key" "$container_name"
            log "INFO" "Удален лейбл $key для контейнера $container_name"
            echo -e "${GREEN}Лейбл удален. Перезапустите контейнер.${NC}"
            ;;
        3)
            echo -e "${YELLOW}Примеры лейблов для Traefik:${NC}"
            echo "  - traefik.enable=true"
            echo "  - traefik.http.routers.myapp.rule=Host(\`example.com\`)"
            echo "  - traefik.http.services.myapp.loadbalancer.server.port=8080"
            echo "  - traefik.http.routers.myapp.tls=true"
            echo "  - traefik.http.routers.myapp.tls.certresolver=myresolver"
            echo "  - traefik.http.middlewares.myapp-auth.basicauth.users=user:$$apr1$$......."
            ;;
        4)
            docker restart "$container_name"
            log "INFO" "Перезапущен контейнер $container_name"
            echo -e "${GREEN}Контейнер $container_name перезапущен.${NC}"
            ;;
        5) 
            log "INFO" "Возврат в главное меню из управления Docker-лейблами"
            return ;;
        *) echo -e "${RED}Неверный вариант!${NC}" ;;
    esac
}

# Создание резервной копии Traefik конфигураций
backup_config() {
    log "INFO" "Запуск создания резервной копии"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/traefik_config_${timestamp}.tar.gz"
    
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${BLUE}Создание резервной копии конфигураций Traefik...${NC}"
    if [ -d "$CONFIG_DIR" ]; then
        tar -czf "$backup_file" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" 2>/dev/null
        
        if [ $? -eq 0 ]; then
            log "INFO" "Резервная копия создана: $backup_file"
            echo -e "${GREEN}Резервная копия создана: $backup_file${NC}"
            
            # Список старых копий и предложение удалить
            local old_backups=$(find "$BACKUP_DIR" -name "traefik_config_*.tar.gz" -type f -mtime +7 | wc -l)
            if [ "$old_backups" -gt 0 ]; then
                echo -e "${YELLOW}Найдено $old_backups старых резервных копий (>7 дней)${NC}"
                read -p "Удалить старые копии? (y/n): " clean_answer
                if [ "$clean_answer" = "y" ]; then
                    find "$BACKUP_DIR" -name "traefik_config_*.tar.gz" -type f -mtime +7 -delete
                    log "INFO" "Удалены старые резервные копии"
                    echo -e "${GREEN}Старые резервные копии удалены.${NC}"
                fi
            fi
        else
            log "ERROR" "Ошибка при создании резервной копии"
            echo -e "${RED}Ошибка при создании резервной копии!${NC}"
        fi
    else
        log "ERROR" "Директория конфигураций не существует: $CONFIG_DIR"
        echo -e "${RED}Ошибка: Директория конфигураций не существует!${NC}"
    fi
}

# Мониторинг состояния и метрик Traefik
monitor_traefik() {
    log "INFO" "Запуск мониторинга Traefik"
    echo -e "${BLUE}Проверка состояния Traefik...${NC}"
    
    if docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
        log "INFO" "Traefik запущен в Docker"
        echo -e "${GREEN}Traefik запущен в Docker${NC}"
        echo -e "${YELLOW}Статистика контейнера:${NC}"
        docker stats --no-stream "$TRAEFIK_CONTAINER_NAME"
        
        # Проверяем наличие метрик
        read -p "Проверить метрики Traefik? (y/n): " metrics_answer
        if [ "$metrics_answer" = "y" ]; then
            read -p "Укажите адрес метрик (по умолчанию: http://localhost:8080/metrics): " metrics_url
            metrics_url=${metrics_url:-"http://localhost:8080/metrics"}
            log "INFO" "Проверка метрик: $metrics_url"
            
            if command -v curl &> /dev/null; then
                curl -s "$metrics_url" | head -n 20
            else
                echo -e "${YELLOW}Curl не установлен, невозможно проверить метрики${NC}"
            fi
        fi
    elif kubectl get pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null | grep -q "traefik"; then
        log "INFO" "Traefik запущен в Kubernetes"
        echo -e "${GREEN}Traefik запущен в Kubernetes${NC}"
        kubectl get pods -n "$TRAEFIK_NAMESPACE"
        
        # Проверяем наличие metrics-server
        if kubectl api-resources | grep -q metrics.k8s.io; then
            kubectl top pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null
        else
            echo -e "${YELLOW}Metrics-server не установлен${NC}"
            log "WARNING" "Metrics-server не установлен в Kubernetes"
        fi
        
        # Получение логов
        read -p "Показать логи Traefik? (y/n): " logs_answer
        if [ "$logs_answer" = "y" ]; then
            kubectl logs -l app.kubernetes.io/name=traefik -n "$TRAEFIK_NAMESPACE" --tail=50
        fi
    else
        log "WARNING" "Traefik не найден ни в Docker, ни в Kubernetes"
        echo -e "${RED}Traefik не найден ни в Docker, ни в Kubernetes!${NC}"
    fi
}

# Проверка настроек безопасности Traefik
check_security() {
    log "INFO" "Запуск проверки безопасности"
    echo -e "${BLUE}Проверка настроек безопасности Traefik...${NC}"
    
    local security_issues=0
    
    # Проверка на открытый панель управления
    if command -v curl &> /dev/null; then
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/dashboard/ 2>/dev/null | grep -q "200"; then
            log "WARNING" "Панель управления Traefik доступна без аутентификации"
            echo -e "${RED}Внимание! Панель управления Traefik доступна без аутентификации!${NC}"
            security_issues=$((security_issues+1))
        else
            echo -e "${GREEN}Панель управления защищена или отключена${NC}"
        fi
    else
        echo -e "${YELLOW}Curl не установлен, невозможно проверить доступность панели управления${NC}"
    fi
    
    # Проверка TLS настроек
    if [ -f "$CONFIG_DIR/traefik.yml" ]; then
        if grep -q "insecureSkipVerify: true" "$CONFIG_DIR/traefik.yml"; then
            log "WARNING" "Обнаружен небезопасный параметр insecureSkipVerify: true"
            echo -e "${RED}Внимание! Обнаружен небезопасный параметр insecureSkipVerify: true${NC}"
            security_issues=$((security_issues+1))
        fi
        
        # Проверка настроек сертификатов
        if ! grep -q "certResolver" "$CONFIG_DIR/traefik.yml" && ! ls "$DYNAMIC_CONFIG_DIR"/*.yml 2>/dev/null | xargs grep -l "certResolver" &>/dev/null; then
            log "WARNING" "Не найдены настройки для автоматического обновления сертификатов"
            echo -e "${YELLOW}Не найдены настройки для автоматического обновления сертификатов${NC}"
            security_issues=$((security_issues+1))
        fi
    fi
    
    # Проверка на работу под root в Docker
    if docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
        if docker inspect "$TRAEFIK_CONTAINER_NAME" --format '{{.Config.User}}' | grep -q "^$" || \
           docker inspect "$TRAEFIK_CONTAINER_NAME" --format '{{.Config.User}}' | grep -q "^0$" || \
           docker inspect "$TRAEFIK_CONTAINER_NAME" --format '{{.Config.User}}' | grep -q "^root$"; then
            log "WARNING" "Traefik работает в Docker под root пользователем"
            echo -e "${YELLOW}Traefik работает в Docker под root пользователем. Рекомендуется использовать непривилегированного пользователя${NC}"
            security_issues=$((security_issues+1))
        fi
    fi
    
    if [ $security_issues -eq 0 ]; then
        echo -e "${GREEN}Проблем безопасности не обнаружено.${NC}"
    fi
    
    echo -e "${YELLOW}Рекомендации по безопасности:${NC}"
    echo "1. Всегда используйте middleware для аутентификации к Dashboard"
    echo "2. Используйте TLS для всех сервисов"
    echo "3. Рассмотрите использование IP allow-листов"
    echo "4. Регулярно обновляйте Traefik до последней версии"
    echo "5. Запускайте Traefik под непривилегированным пользователем"
    
    read -p "Нажмите Enter для продолжения..."
}

# Установка Traefik в Docker
install_traefik_docker() {
    log "INFO" "Запуск установки Traefik в Docker"
    echo -e "${BLUE}Установка Traefik в Docker...${NC}"
    
    # Создание необходимых директорий
    mkdir -p "$CONFIG_DIR" "$DYNAMIC_CONFIG_DIR"
    
    # Создание базового конфига
    local config_file="$CONFIG_DIR/traefik.yml"
    local temp_config=$(mktemp)
    TEMP_FILES+=("$temp_config")
    
    cat <<EOF > "$temp_config"
global:
  checkNewVersion: true
  sendAnonymousUsage: false

api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: "/etc/traefik/conf.d"
    watch: true

log:
  level: "INFO"

accessLog: {}
EOF

    sudo mv "$temp_config" "$config_file"
    
    # Создание сети для Traefik
    if ! docker network ls | grep -q "traefik-net"; then
        docker network create traefik-net
        log "INFO" "Создана сеть traefik-net"
    fi
    
    # Запуск Traefik
    echo -e "${GREEN}Запуск Traefik контейнера...${NC}"
    docker run -d \
      --name "$TRAEFIK_CONTAINER_NAME" \
      --restart=unless-stopped \
      --network=traefik-net \
      -p 80:80 \
      -p 443:443 \
      -p 127.0.0.1:8080:8080 \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      -v "$CONFIG_DIR/traefik.yml:/etc/traefik/traefik.yml:ro" \
      -v "$DYNAMIC_CONFIG_DIR:/etc/traefik/conf.d:ro" \
      -v "$CONFIG_DIR/acme.json:/acme.json" \
      -u 1000:1000 \
      --label "traefik.enable=true" \
      --label "traefik.http.routers.dashboard.rule=Host(\`traefik.localhost\`)" \
      --label "traefik.http.routers.dashboard.service=api@internal" \
      --label "traefik.http.routers.dashboard.middlewares=auth" \
      --label "traefik.http.middlewares.auth.basicauth.users=admin:$$apr1$$QaCrEWhP$$VMHsCJ9t3JUcbVL.vMGsB1" \
      traefik:latest
      
    if [ $? -eq 0 ]; then
        log "INFO" "Traefik успешно установлен и запущен в Docker"
        echo -e "${GREEN}Traefik успешно установлен и запущен.${NC}"
        echo -e "Панель управления доступна по адресу: http://traefik.localhost"
        echo -e "Логин: admin, Пароль: admin (рекомендуется изменить)"
        
        # Создаем файл для Let's Encrypt сертификатов с правильными правами
        sudo touch "$CONFIG_DIR/acme.json"
        sudo chmod 600 "$CONFIG_DIR/acme.json"
    else
        log "ERROR" "Ошибка при запуске Traefik контейнера"
        echo -e "${RED}Ошибка при запуске Traefik контейнера!${NC}"
    fi
}

# Установка Traefik в Kubernetes
install_traefik_k8s() {
    log "INFO" "Запуск установки Traefik в Kubernetes"
    echo -e "${BLUE}Установка Traefik в Kubernetes...${NC}"
    
    # Проверка подключения к Kubernetes
    check_k8s_connection || return
    
    # Проверка наличия Helm
    if ! command -v helm &> /dev/null; then
        log "WARNING" "Helm не установлен"
        echo -e "${YELLOW}Helm не установлен. Установить? (y/n): ${NC}"
        read -p "" install_helm
        if [ "$install_helm" = "y" ]; then
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            if [ $? -ne 0 ]; then
                log "ERROR" "Ошибка при установке Helm"
                echo -e "${RED}Ошибка при установке Helm!${NC}"
                return
            fi
        else
            log "ERROR" "Helm требуется для установки Traefik в Kubernetes"
            echo -e "${RED}Helm требуется для установки Traefik в Kubernetes.${NC}"
            return
        fi
    fi
    
    # Создание namespace
    kubectl create namespace "$TRAEFIK_NAMESPACE" 2>/dev/null || true
    
    # Добавление репозитория Traefik
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    
    # Создание временного файла с values для Helm
    local values_file=$(mktemp)
    TEMP_FILES+=("$values_file")
    
    cat <<EOF > "$values_file"
dashboard:
  enabled: true
  auth:
    basic:
      admin: admin

ports:
  web:
    port: 80
    exposedPort: 80
  websecure:
    port: 443
    exposedPort: 443

providers:
  kubernetesCRD:
    enabled: true
    namespaces: []
  kubernetesIngress:
    enabled: true
    namespaces: []

logs:
  general:
    level: INFO
  access:
    enabled: true
EOF
    
    # Установка Traefik через Helm
    echo -e "${GREEN}Установка Traefik через Helm...${NC}"
    helm upgrade --install traefik traefik/traefik \
      --namespace="$TRAEFIK_NAMESPACE" \
      --values="$values_file" \
      --wait
    
    if [ $? -eq 0 ]; then
        log "INFO" "Traefik успешно установлен в Kubernetes"
        echo -e "${GREEN}Traefik успешно установлен в Kubernetes.${NC}"
        echo -e "Для доступа к панели управления выполните:"
        echo -e "kubectl port-forward -n $TRAEFIK_NAMESPACE \$(kubectl get pods -n $TRAEFIK_NAMESPACE -l app.kubernetes.io/name=traefik -o name) 9000:9000"
    else
        log "ERROR" "Ошибка при установке Traefik в Kubernetes"
        echo -e "${RED}Ошибка при установке Traefik в Kubernetes!${NC}"
    fi
}

# Обновление скрипта
update_script() {
    log "INFO" "Запуск процедуры обновления скрипта"
    echo -e "${BLUE}Проверка наличия обновлений...${NC}"
    
    local script_path=$(realpath "$0")
    local backup_script="${script_path}.backup"
    
    # Создаем резервную копию текущего скрипта
    cp "$script_path" "$backup_script"
    
    # Здесь можно реализовать логику проверки и загрузки обновлений
    # Например, с GitHub или другого репозитория
    
    echo -e "${YELLOW}Автоматическое обновление не настроено.${NC}"
    echo -e "${YELLOW}Текущая версия: $VERSION${NC}"
    echo -e "${GREEN}Резервная копия скрипта создана: $backup_script${NC}"
}

# Главное меню
main_menu() {
    while true; do
        echo -e "
        ${BLUE}=== Управление Traefik v${VERSION} ===${NC}
        ${GREEN}1) Управление Docker-контейнерами (лейблы)"
        
        # Добавляем пункты меню только если Kubernetes доступен
        if [ "$K8S_ENABLED" = true ]; then
            echo -e "        2) Управление Kubernetes (IngressRoute)"
        fi
        
        echo -e "        3) Редактировать основной конфиг (traefik.yml)
        4) Редактировать динамические конфиги (в conf.d/)
        5) Перезапустить Traefik
        6) Проверить конфигурацию
        7) Создать резервную копию конфигураций
        8) Мониторинг Traefik
        9) Проверка безопасности
        10) Установить Traefik"
        
        # Дополнительный пункт для включения/отключения Kubernetes
        if [ "$K8S_ENABLED" = false ]; then
            echo -e "        11) Включить поддержку Kubernetes"
        else
            echo -e "        11) Отключить поддержку Kubernetes"
        fi
        
        echo -e "        12) Обновить этот скрипт
        13) Выйти${NC}
        "
        read -p "Выберите действие: " choice

        case $choice in
            1) manage_docker_labels ;;
            2) 
                # Проверяем, доступен ли Kubernetes перед выполнением
                if [ "$K8S_ENABLED" = true ]; then
                    manage_ingress_route
                else
                    echo -e "${RED}Kubernetes не включен! Выберите пункт 11 для включения.${NC}"
                fi
                ;;
            3) 
                log "INFO" "Редактирование основного конфига"
                sudo nano "$CONFIG_DIR/traefik.yml" 
                ;;
            4)
                log "INFO" "Редактирование динамических конфигов"
                echo -e "${GREEN}Доступные конфиги:${NC}"
                ls -l "$DYNAMIC_CONFIG_DIR"/*.yml 2>/dev/null || echo "Нет файлов конфигурации."
                read -p "Введите имя файла (например, example.yml): " file_name
                sudo nano "$DYNAMIC_CONFIG_DIR/$file_name"
                ;;
            5) 
                log "INFO" "Перезапуск Traefik"
                # Создаем резервную копию перед перезапуском
                backup_config
                
                if docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
                    docker restart "$TRAEFIK_CONTAINER_NAME"
                    log "INFO" "Traefik контейнер перезапущен"
                    echo -e "${GREEN}Traefik контейнер перезапущен.${NC}"
                elif [ "$K8S_ENABLED" = true ] && kubectl get pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null | grep -q "traefik"; then
                    kubectl rollout restart deployment/traefik -n "$TRAEFIK_NAMESPACE"
                    log "INFO" "Traefik deployment перезапущен в Kubernetes"
                    echo -e "${GREEN}Traefik deployment перезапущен в Kubernetes.${NC}"
                else
                    log "ERROR" "Traefik не найден ни в Docker, ни в Kubernetes"
                    echo -e "${RED}Traefik не найден ни в Docker, ни в Kubernetes!${NC}"
                fi
                ;;
            6) 
                log "INFO" "Проверка конфигурации Traefik"
                if docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
                    docker exec "$TRAEFIK_CONTAINER_NAME" traefik version
                    docker exec "$TRAEFIK_CONTAINER_NAME" traefik healthcheck
                else
                    echo -e "${RED}Traefik контейнер не запущен!${NC}"
                fi
                ;;
            7) backup_config ;;
            8) monitor_traefik ;;
            9) check_security ;;
            10)
                echo -e "
                ${YELLOW}1) Установить Traefik в Docker
                2) Установить Traefik в Kubernetes
                3) Вернуться в меню${NC}
                "
                read -p "Выберите действие: " install_choice
                case $install_choice in
                    1) install_traefik_docker ;;
                    2) 
                        if [ "$K8S_ENABLED" = true ]; then
                            install_traefik_k8s
                        else
                            echo -e "${RED}Kubernetes не включен! Выберите пункт 11 для включения.${NC}"
                        fi
                        ;;
                    3) ;;
                    *) echo -e "${RED}Неверный вариант!${NC}" ;;
                esac
                ;;
            11) 
                if [ "$K8S_ENABLED" = false ]; then
                    log "INFO" "Включение поддержки Kubernetes"
                    echo -e "${YELLOW}Включение поддержки Kubernetes...${NC}"
                    if check_kubernetes || install_kubernetes; then
                        K8S_ENABLED=true
                        echo -e "${GREEN}Поддержка Kubernetes включена.${NC}"
                    else
                        echo -e "${RED}Не удалось включить поддержку Kubernetes.${NC}"
                    fi
                else
                    log "INFO" "Отключение поддержки Kubernetes"
                    echo -e "${YELLOW}Отключение поддержки Kubernetes...${NC}"
                    read -p "Вы точно хотите отключить поддержку Kubernetes? (y/n): " disable_k8s
                    if [ "$disable_k8s" = "y" ]; then
                        K8S_ENABLED=false
                        echo -e "${GREEN}Поддержка Kubernetes отключена.${NC}"
                    fi
                fi
                ;;
            12) update_script ;;
            13) 
                log "INFO" "Завершение работы скрипта"
                exit 0 
                ;;
            *) echo -e "${RED}Неверный вариант!${NC}" ;;
        esac
    done
}

# --- Точка входа ---
clear
echo -e "${BLUE}=== Traefik Management Script v${VERSION} (Kubernetes + Docker) ===${NC}"
log "INFO" "Скрипт запущен пользователем $(whoami)"

# Проверка прав
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Скрипт требует root-прав. Запуск с sudo...${NC}"
    log "WARNING" "Перезапуск скрипта с sudo правами"
    exec sudo "$0" "$@"
fi

# Создание директорий для логов и бэкапов
mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" 2>/dev/null || true

# Установка зависимостей и проверка Kubernetes
install_dependencies

# Проверка наличия и запуск Traefik при необходимости
if ! docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
    log "WARNING" "Traefik контейнер не запущен"
    echo -e "${YELLOW}Traefik контейнер не запущен.${NC}"
    
    # Проверяем Kubernetes только если он включен
    if [ "$K8S_ENABLED" = true ] && ! kubectl get pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null | grep -q "traefik"; then
        log "WARNING" "Traefik не найден ни в Docker, ни в Kubernetes"
        echo -e "${RED}Traefik не найден ни в Docker, ни в Kubernetes!${NC}"
        read -p "Установить Traefik? (y/n): " install_answer
        if [ "$install_answer" = "y" ]; then
            echo -e "
            ${YELLOW}1) Установить в Docker
            2) Установить в Kubernetes${NC}
            "
            read -p "Выберите вариант: " install_option
            case $install_option in
                1) install_traefik_docker ;;
                2) 
                    if [ "$K8S_ENABLED" = true ]; then
                        install_traefik_k8s
                    else
                        echo -e "${RED}Kubernetes не включен! Установка в Kubernetes невозможна.${NC}"
                        read -p "Установить в Docker? (y/n): " docker_fallback
                        if [ "$docker_fallback" = "y" ]; then
                            install_traefik_docker
                        fi
                    fi
                    ;;
                *) 
                    echo -e "${RED}Неверный вариант, продолжение без Traefik.${NC}"
                    log "WARNING" "Продолжение без установки Traefik"
                    ;;
            esac
        else
            echo -e "${YELLOW}Продолжение без Traefik. Некоторые функции могут быть недоступны.${NC}"
            log "WARNING" "Пользователь выбрал продолжение без Traefik"
        fi
    elif [ "$K8S_ENABLED" = true ]; then
        log "INFO" "Traefik запущен в Kubernetes"
    fi
else
    log "INFO" "Traefik запущен в Docker"
fi

main_menu

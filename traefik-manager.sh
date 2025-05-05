#!/bin/bash

# Конфигурационные переменные
CONFIG_DIR="/etc/traefik"
DYNAMIC_CONFIG_DIR="$CONFIG_DIR/conf.d"
TRAEFIK_CONTAINER_NAME="traefik"
TRAEFIK_NAMESPACE="traefik"  # Для Kubernetes
REQUIRED_PACKAGES=("jq" "docker" "kubectl")  # Обязательные пакеты

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Функции ---

# Проверка и установка зависимостей
install_dependencies() {
    echo -e "${YELLOW}Проверка зависимостей...${NC}"
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            echo -e "${RED}Ошибка: $pkg не установлен!${NC}"
            read -p "Установить автоматически? (y/n): " answer
            if [ "$answer" = "y" ]; then
                case "$pkg" in
                    "jq")
                        echo -e "${GREEN}Устанавливаю jq...${NC}"
                        sudo apt update && sudo apt install -y jq || {
                            echo -e "${RED}Ошибка установки jq!${NC}"
                            exit 1
                        }
                        ;;
                    "docker")
                        echo -e "${GREEN}Устанавливаю Docker...${NC}"
                        curl -fsSL https://get.docker.com | sh || {
                            echo -e "${RED}Ошибка установки Docker!${NC}"
                            exit 1
                        }
                        sudo usermod -aG docker "$USER"
                        ;;
                    "kubectl")
                        echo -e "${GREEN}Устанавливаю kubectl...${NC}"
                        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
                        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || {
                            echo -e "${RED}Ошибка установки kubectl!${NC}"
                            exit 1
                        }
                        ;;
                esac
                echo -e "${GREEN}$pkg успешно установлен.${NC}"
            else
                echo -e "${RED}Прерывание: $pkg обязателен для работы скрипта.${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}$pkg установлен.${NC}"
        fi
    done
}

# Проверка подключения к Kubernetes
check_k8s_connection() {
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Ошибка подключения к Kubernetes!${NC}"
        echo "Убедитесь что:"
        echo "1. kubectl настроен правильно"
        echo "2. KUBECONFIG указан или конфиг в ~/.kube/config"
        return 1
    fi
    return 0
}

# Управление IngressRoute (Traefik CRD)
manage_ingress_route() {
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
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}

            temp_file=$(mktemp)
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
            rm "$temp_file"
            ;;
        2)
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}
            kubectl edit ingressroute "$name" -n "$ns"
            ;;
        3)
            read -p "Введите имя IngressRoute: " name
            read -p "Введите namespace (по умолчанию: $TRAEFIK_NAMESPACE): " ns
            ns=${ns:-$TRAEFIK_NAMESPACE}
            kubectl delete ingressroute "$name" -n "$ns"
            ;;
        4) return ;;
        *) echo -e "${RED}Неверный вариант!${NC}" ;;
    esac
}

# Управление Docker-лейблами (из предыдущей версии)
manage_docker_labels() {
    echo -e "${BLUE}Список запущенных контейнеров:${NC}"
    docker ps --format "{{.Names}}"

    read -p "Введите имя контейнера: " container_name
    if ! docker inspect "$container_name" &> /dev/null; then
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
            echo -e "${GREEN}Лейбл добавлен. Не забудьте перезапустить контейнер.${NC}"
            ;;
        2)
            read -p "Ключ лейбла для удаления: " key
            docker container update --label-rm "$key" "$container_name"
            echo -e "${GREEN}Лейбл удален. Перезапустите контейнер.${NC}"
            ;;
        3)
            echo -e "${YELLOW}Примеры лейблов для Traefik:${NC}"
            echo "  - traefik.enable=true"
            echo "  - traefik.http.routers.myapp.rule=Host(\`example.com\`)"
            echo "  - traefik.http.services.myapp.loadbalancer.server.port=8080"
            echo "  - traefik.http.routers.myapp.tls=true"
            ;;
        4)
            docker restart "$container_name"
            echo -e "${GREEN}Контейнер $container_name перезапущен.${NC}"
            ;;
        5) return ;;
        *) echo -e "${RED}Неверный вариант!${NC}" ;;
    esac
}

# Главное меню
main_menu() {
    while true; do
        echo -e "
        ${BLUE}=== Управление Traefik ===${NC}
        ${GREEN}1) Управление Docker-контейнерами (лейблы)
        2) Управление Kubernetes (IngressRoute)
        3) Редактировать основной конфиг (traefik.yml)
        4) Редактировать динамические конфиги (в conf.d/)
        5) Перезапустить Traefik
        6) Проверить конфигурацию
        7) Выйти${NC}
        "
        read -p "Выберите действие: " choice

        case $choice in
            1) manage_docker_labels ;;
            2) manage_ingress_route ;;
            3) sudo nano "$CONFIG_DIR/traefik.yml" ;;
            4)
                echo -e "${GREEN}Доступные конфиги:${NC}"
                ls -l "$DYNAMIC_CONFIG_DIR"/*.yml 2>/dev/null || echo "Нет файлов конфигурации."
                read -p "Введите имя файла (например, example.yml): " file_name
                sudo nano "$DYNAMIC_CONFIG_DIR/$file_name"
                ;;
            5) docker restart "$TRAEFIK_CONTAINER_NAME" ;;
            6) docker exec "$TRAEFIK_CONTAINER_NAME" traefik check-config ;;
            7) exit 0 ;;
            *) echo -e "${RED}Неверный вариант!${NC}" ;;
        esac
    done
}

# --- Точка входа ---
clear
echo -e "${BLUE}=== Traefik Management Script (Kubernetes + Docker) ===${NC}"

# Проверка прав
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Скрипт требует root-прав. Запуск с sudo...${NC}"
    exec sudo "$0" "$@"
fi

# Установка зависимостей
install_dependencies

# Проверка, запущен ли Traefik
if ! docker ps --format '{{.Names}}' | grep -q "$TRAEFIK_CONTAINER_NAME"; then
    echo -e "${YELLOW}Traefik контейнер не запущен. Проверяю Kubernetes...${NC}"
    if ! kubectl get pods -n "$TRAEFIK_NAMESPACE" 2>/dev/null | grep -q "traefik"; then
        echo -e "${RED}Traefik не найден ни в Docker, ни в Kubernetes!${NC}"
        exit 1
    fi
fi

main_menu

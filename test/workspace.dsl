workspace "Test" "Тест с тремя системами и шлюзом" {
    model {
        user = person "Пользователь"
        gateway = softwareSystem "API Gateway" "Точка входа"
        system1 = softwareSystem "Первая система"
        system2 = softwareSystem "Вторая система"
        database = softwareSystem "База данных"
        
        user -> gateway "HTTPS"
        gateway -> system1 "Маршрутизирует"
        gateway -> system2 "Маршрутизирует"
        system1 -> database "Читает/пишет"
        system2 -> database "Читает/пишет"
    }
    views {
        systemLandscape "Landscape" {
            include *
            autolayout lr
        }
        theme default
    }
}

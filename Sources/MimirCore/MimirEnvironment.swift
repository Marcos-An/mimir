import Foundation

/// Configuração de ambiente resolvida a partir de variáveis do processo.
/// Deixa os pontos pessoais do usuário (paths, integrações opcionais)
/// fora do código-fonte e fáceis de sobrescrever por quem roda o app.
public enum MimirEnvironment {
    /// Caminho para o binário do Hermes (integração opcional). Resolvido em ordem:
    /// 1. `$HERMES_PATH` explícito
    /// 2. `~/.local/bin/hermes` se existir
    /// 3. `nil` → feature desabilitada na UI.
    public static var hermesExecutablePath: String? {
        if let explicit = ProcessInfo.processInfo.environment["HERMES_PATH"],
           !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        let defaultPath = (NSString(string: "~/.local/bin/hermes")).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }
        return nil
    }

    /// Indica se a integração Hermes tem um binário executável disponível.
    public static var isHermesAvailable: Bool {
        hermesExecutablePath != nil
    }

    /// Diretório de trabalho sugerido para processos lançados pelo Mimir.
    /// Resolvido via `$MIMIR_WORKING_DIR` ou default para a home do usuário.
    public static var defaultWorkingDirectory: String {
        if let explicit = ProcessInfo.processInfo.environment["MIMIR_WORKING_DIR"],
           !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        return NSHomeDirectory()
    }
}

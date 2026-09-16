import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Properties;
import java.util.Set;

/** Retained, protocol-only JDBC process used by Orbit's MSSQL Connector. */
public final class OrbitMssql {
    private static final String PROTOCOL = "ORBIT/1";
    private static final int MAX_HEADER_BYTES = 8192;
    private static final int MAX_FIELD_BYTES = 128 * 1024 * 1024;

    private final BufferedInputStream input = new BufferedInputStream(System.in);
    private final BufferedOutputStream output = new BufferedOutputStream(System.out);
    private Connection connection;
    private ConnectionSettings connectionSettings;

    public static void main(String[] args) {
        if (Runtime.version().feature() < 11) {
            System.err.println("Orbit MSSQL helper requires Java 11 or newer");
            System.exit(2);
        }
        try {
            Class<?> driverClass = Class.forName("net.sourceforge.jtds.jdbc.Driver");
            String driverVersion = driverClass.getPackage().getImplementationVersion();
            if (!"1.3.1".equals(driverVersion)) {
                throw new IllegalStateException("Orbit MSSQL helper requires jTDS 1.3.1, found " + driverVersion);
            }
            if (args.length == 1 && "--doctor".equals(args[0])) {
                System.out.println("Orbit MSSQL helper: Java " + Runtime.version().feature() + "; jTDS 1.3.1 loaded");
                return;
            }
            if (args.length != 0) {
                throw new IllegalArgumentException("Orbit MSSQL helper accepts only --doctor");
            }
            new OrbitMssql().run();
        } catch (Throwable error) {
            System.err.println("Orbit MSSQL helper failed: " + safeMessage(error));
            System.exit(1);
        }
    }

    private void run() throws IOException {
        while (true) {
            Request request = readRequest();
            if (request == null) {
                closeConnection();
                return;
            }
            boolean fatal = false;
            String response;
            try {
                ensureConnection(request.settings);
                response = execute(request.statement);
            } catch (SQLException error) {
                fatal = connection == null || connectionFailure(error);
                response = errorResponse(safeMessage(error), fatal);
            }
            writeResponse(request.marker, response);
            if (fatal) {
                closeConnection();
                return;
            }
        }
    }

    private void ensureConnection(ConnectionSettings settings) throws SQLException {
        if (connection != null) {
            if (connection.isClosed()) {
                throw new SQLException("MSSQL JDBC connection is closed", "08003");
            }
            if (!settings.equals(connectionSettings)) {
                throw new SQLException("MSSQL JDBC settings changed inside a retained session", "08003");
            }
            return;
        }
        Properties properties = new Properties();
        properties.setProperty("user", settings.user);
        properties.setProperty("password", settings.password);
        properties.setProperty("ssl", settings.trustServerCertificate ? "require" : "authenticate");
        if (!settings.database.isEmpty()) {
            properties.setProperty("databaseName", settings.database);
        }
        if (!settings.instance.isEmpty()) {
            properties.setProperty("instance", settings.instance);
        }
        if (settings.domainAuthentication) {
            properties.setProperty("domain", settings.domain);
            properties.setProperty("useNTLMv2", "true");
        }
        // Credentials and driver properties stay in Properties; only the
        // validated host and numeric port become part of the JDBC URL.
        String url = "jdbc:jtds:sqlserver://" + settings.host;
        if (settings.port != 0) {
            url += ":" + settings.port;
        }
        connection = DriverManager.getConnection(url, properties);
        connectionSettings = settings;
    }

    private String execute(String sql) throws SQLException {
        List<String> columns = null;
        List<List<String>> rows = null;
        int tabularResults = 0;
        try (Statement statement = connection.createStatement()) {
            boolean resultAvailable = statement.execute(sql);
            while (true) {
                if (resultAvailable) {
                    tabularResults++;
                    if (tabularResults > 1) {
                        throw new SQLException("MSSQL JDBC statements may return only one tabular result");
                    }
                    try (ResultSet result = statement.getResultSet()) {
                        ResultData data = readResult(result);
                        columns = data.columns;
                        rows = data.rows;
                    }
                } else if (statement.getUpdateCount() == -1) {
                    break;
                }
                resultAvailable = statement.getMoreResults(Statement.CLOSE_CURRENT_RESULT);
            }
        }
        if (columns == null) {
            columns = new ArrayList<>();
            rows = new ArrayList<>();
        }
        return successResponse(columns, rows);
    }

    private ResultData readResult(ResultSet result) throws SQLException {
        ResultSetMetaData metadata = result.getMetaData();
        int width = metadata.getColumnCount();
        List<String> columns = new ArrayList<>(width);
        Set<String> seen = new HashSet<>();
        for (int index = 1; index <= width; index++) {
            String label = metadata.getColumnLabel(index);
            if (label == null || label.isEmpty()) {
                throw new SQLException("MSSQL JDBC result column " + index + " label must not be empty");
            }
            if (!seen.add(label)) {
                throw new SQLException("MSSQL JDBC result has duplicate label " + label);
            }
            columns.add(label);
        }
        List<List<String>> rows = new ArrayList<>();
        while (result.next()) {
            List<String> row = new ArrayList<>(width);
            for (int index = 1; index <= width; index++) {
                String value = result.getString(index);
                row.add(result.wasNull() ? null : value);
            }
            rows.add(row);
        }
        return new ResultData(columns, rows);
    }

    private Request readRequest() throws IOException {
        String header = readAsciiLine();
        if (header == null) {
            return null;
        }
        String[] parts = header.split(" ", -1);
        if (parts.length != 12 || !PROTOCOL.equals(parts[0]) || !parts[1].matches("[A-Za-z0-9_]+")) {
            throw new IOException("malformed request header");
        }
        int hostLength = length(parts[2]);
        int port = integer(parts[3], 0, 65535, "port");
        int instanceLength = length(parts[4]);
        int databaseLength = length(parts[5]);
        boolean domainAuthentication;
        if ("D".equals(parts[6])) {
            domainAuthentication = true;
        } else if ("S".equals(parts[6])) {
            domainAuthentication = false;
        } else {
            throw new IOException("unsupported authentication mode");
        }
        int domainLength = length(parts[7]);
        int userLength = length(parts[8]);
        int passwordLength = length(parts[9]);
        int statementLength = length(parts[10]);
        boolean trustServerCertificate;
        if ("1".equals(parts[11])) {
            trustServerCertificate = true;
        } else if ("0".equals(parts[11])) {
            trustServerCertificate = false;
        } else {
            throw new IOException("invalid certificate trust flag");
        }

        String host = readUtf8(hostLength);
        String instance = readUtf8(instanceLength);
        String database = readUtf8(databaseLength);
        String domain = readUtf8(domainLength);
        String user = readUtf8(userLength);
        String password = readUtf8(passwordLength);
        String statement = readUtf8(statementLength);
        ConnectionSettings settings = new ConnectionSettings(
                host, port, instance, database, domainAuthentication, domain, user, password, trustServerCertificate);
        return new Request(parts[1], settings, statement);
    }

    private String readAsciiLine() throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        while (line.size() <= MAX_HEADER_BYTES) {
            int value = input.read();
            if (value == -1) {
                if (line.size() == 0) {
                    return null;
                }
                throw new EOFException("incomplete request header");
            }
            if (value == '\n') {
                return line.toString(StandardCharsets.US_ASCII);
            }
            if (value < 0x20 || value > 0x7e) {
                throw new IOException("request header is not ASCII");
            }
            line.write(value);
        }
        throw new IOException("request header is too large");
    }

    private String readUtf8(int length) throws IOException {
        byte[] bytes = input.readNBytes(length);
        if (bytes.length != length) {
            throw new EOFException("incomplete request payload");
        }
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes))
                    .toString();
        } catch (CharacterCodingException error) {
            throw new IOException("request payload is not UTF-8", error);
        }
    }

    private void writeResponse(String marker, String payload) throws IOException {
        byte[] bytes = payload.getBytes(StandardCharsets.UTF_8);
        output.write((PROTOCOL + " " + marker + " " + bytes.length + "\n").getBytes(StandardCharsets.US_ASCII));
        output.write(bytes);
        output.flush();
    }

    private static int length(String value) throws IOException {
        return integer(value, 0, MAX_FIELD_BYTES, "field length");
    }

    private static int integer(String value, int minimum, int maximum, String label) throws IOException {
        try {
            int parsed = Integer.parseInt(value);
            if (parsed < minimum || parsed > maximum) {
                throw new IOException(label + " is out of range");
            }
            return parsed;
        } catch (NumberFormatException error) {
            throw new IOException(label + " is not an integer", error);
        }
    }

    private static boolean connectionFailure(SQLException error) {
        for (SQLException current = error; current != null; current = current.getNextException()) {
            String state = current.getSQLState();
            if (state != null && state.startsWith("08")) {
                return true;
            }
        }
        return false;
    }

    private static String successResponse(List<String> columns, List<List<String>> rows) {
        StringBuilder json = new StringBuilder();
        json.append("{\"ok\":true,\"columns\":[");
        for (int index = 0; index < columns.size(); index++) {
            if (index != 0) json.append(',');
            appendJsonString(json, columns.get(index));
        }
        json.append("],\"rows\":[");
        for (int rowIndex = 0; rowIndex < rows.size(); rowIndex++) {
            if (rowIndex != 0) json.append(',');
            json.append('[');
            List<String> row = rows.get(rowIndex);
            for (int columnIndex = 0; columnIndex < row.size(); columnIndex++) {
                if (columnIndex != 0) json.append(',');
                String value = row.get(columnIndex);
                if (value == null) json.append("null");
                else appendJsonString(json, value);
            }
            json.append(']');
        }
        return json.append("]}").toString();
    }

    private static String errorResponse(String message, boolean fatal) {
        StringBuilder json = new StringBuilder("{\"ok\":false,\"fatal\":");
        json.append(fatal ? "true" : "false").append(",\"error\":");
        appendJsonString(json, message);
        return json.append('}').toString();
    }

    private static void appendJsonString(StringBuilder json, String value) {
        json.append('"');
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"': json.append("\\\""); break;
                case '\\': json.append("\\\\"); break;
                case '\b': json.append("\\b"); break;
                case '\f': json.append("\\f"); break;
                case '\n': json.append("\\n"); break;
                case '\r': json.append("\\r"); break;
                case '\t': json.append("\\t"); break;
                default:
                    if (character < 0x20) json.append(String.format("\\u%04x", (int) character));
                    else json.append(character);
            }
        }
        json.append('"');
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return message == null || message.isEmpty() ? error.getClass().getSimpleName() : message;
    }

    private void closeConnection() {
        if (connection == null) return;
        try {
            connection.close();
        } catch (SQLException ignored) {
            // The process is already terminating; there is no caller to recover.
        } finally {
            connection = null;
            connectionSettings = null;
        }
    }

    private static final class Request {
        final String marker;
        final ConnectionSettings settings;
        final String statement;

        Request(String marker, ConnectionSettings settings, String statement) {
            this.marker = marker;
            this.settings = settings;
            this.statement = statement;
        }
    }

    private static final class ResultData {
        final List<String> columns;
        final List<List<String>> rows;

        ResultData(List<String> columns, List<List<String>> rows) {
            this.columns = columns;
            this.rows = rows;
        }
    }

    private static final class ConnectionSettings {
        final String host;
        final int port;
        final String instance;
        final String database;
        final boolean domainAuthentication;
        final String domain;
        final String user;
        final String password;
        final boolean trustServerCertificate;

        ConnectionSettings(String host, int port, String instance, String database, boolean domainAuthentication,
                String domain, String user, String password, boolean trustServerCertificate) {
            this.host = host;
            this.port = port;
            this.instance = instance;
            this.database = database;
            this.domainAuthentication = domainAuthentication;
            this.domain = domain;
            this.user = user;
            this.password = password;
            this.trustServerCertificate = trustServerCertificate;
        }

        @Override
        public boolean equals(Object other) {
            if (!(other instanceof ConnectionSettings)) return false;
            ConnectionSettings settings = (ConnectionSettings) other;
            return port == settings.port
                    && domainAuthentication == settings.domainAuthentication
                    && trustServerCertificate == settings.trustServerCertificate
                    && host.equals(settings.host)
                    && instance.equals(settings.instance)
                    && database.equals(settings.database)
                    && domain.equals(settings.domain)
                    && user.equals(settings.user)
                    && password.equals(settings.password);
        }

        @Override
        public int hashCode() {
            int result = host.hashCode();
            result = 31 * result + port;
            result = 31 * result + instance.hashCode();
            result = 31 * result + database.hashCode();
            result = 31 * result + domain.hashCode();
            result = 31 * result + user.hashCode();
            return result;
        }
    }
}

#ifndef PIPELINE_H__
#define PIPELINE_H__

#include <string>
#include <vector>
#include <map>
#include <set>
#include "PipeFile.h"

class ProcArgs
{
public:
	std::string ToString() const;
	bool IsEmpty() const { return args_.empty(); }
	bool Has(const std::string& key) const { return (args_.find(key) != args_.end()); }
	void Add(const std::string& key, const std::string& value);
	std::string Get(const std::string& key) const;
	void Clear();
private:
	std::map<std::string, std::string> args_;
	std::vector<std::string> order_;
};

class Pipeline;

enum class CommandType { TYPE_SHELL, TYPE_PROC, TYPE_BLOCK };

std::ostream& operator << (std::ostream& os, CommandType type);

class CommandItem
{
public:

	CommandItem() { }
	CommandItem(const std::string& cmd, const std::vector<std::string>& arguments);
	CommandItem(const std::string& procName, const ProcArgs& procArgs);
	explicit CommandItem(const std::string& cmdLine);
	explicit CommandItem(size_t blockIndex);

	bool ConvertShellToProc();

	// common attributes
	CommandType Type() const { return type_; }
	const std::string& Name() const { return name_; }

	// 'shell command' attributes
	const std::string& CmdLine() const;
	const std::string& ShellCmd() const;

	// 'procedure' attributes
	const std::string& ProcName() const;
	const ProcArgs& GetProcArgs() const;

	// 'block' attributes
	size_t GetBlockIndex() const;

	std::string ToString() const;
	std::string ToString(const std::string& indent, const Pipeline& pipeline) const;
	void Dump(const std::string& indent, const Pipeline& pipeline) const;
	std::string DetailToString() const;
private:
	CommandType type_ = CommandType::TYPE_SHELL;
	std::string name_;
	ProcArgs procArgs_;

	// members for 'shell command'
	std::string fullCmdLine_;
	std::string shellCmd_;
	std::vector<std::string> shellArgs_;

	// members for 'procedure'
	std::string procName_;

	// members for 'block'
	size_t blockIndex_ = 0;
};

class Block
{
public:
	void Clear();

	void SetParallel(bool parallel) { parallel_ = parallel; }
	void AppendCommand(const std::vector<std::vector<std::string>>& argLists, Pipeline& pipeline);
	void AppendCommand(const std::string& cmd, const std::vector<std::string>& arguments);
	void AppendCommand(const std::string& procName, const ProcArgs& procArgs);

	bool AppendBlock(size_t blockIndex);
	bool UpdateCommandToProcCalling(const std::set<std::string>& procNameSet);

	bool HasAnyCommand() const { return !items_.empty(); }

	std::string ToString(const std::string& indent, const Pipeline& pipeline) const;
	void Dump(const std::string& indent, const Pipeline& pipeline) const;
	std::string DetailToString() const;

	const std::vector<CommandItem>& GetItems() const { return items_; }
	bool IsParallel() const { return parallel_; }
private:
	std::vector<CommandItem> items_;
	bool parallel_ = false;
};

class Procedure
{
public:
	void Initialize(const std::string& name, size_t blockIndex) { name_ = name; blockIndex_ = blockIndex; }

	std::string Name() const { return name_; }
	size_t BlockIndex() const { return blockIndex_; }
private:
	std::string name_;
	size_t blockIndex_ = 0;
};

class Pipeline
{
public:
	static bool CheckIfPipeFile(const std::string& command);

	bool Load(const std::string& filename);
	bool FinalCheckAfterLoad();
	bool Save(const std::string& filename) const;

	bool SetDefaultBlock(const std::vector<std::string>& cmdList, bool parallel);
	bool SetDefaultBlock(const std::string& cmd, const std::vector<std::string>& arguments);
	bool SetDefaultBlock(const std::string& procName, const ProcArgs& procArgs);

	size_t AppendBlock(const Block& block);

	bool HasProcedure(const std::string& name) const;
	bool HasAnyDefaultCommand() const;

	const Block& GetDefaultBlock() const;
	const Block& GetBlock(size_t index) const;
	const Block& GetBlock(const std::string& procName) const;
	std::vector<std::string> GetProcNameList(const std::string& pattern) const;

	void Dump() const;
private:
	bool LoadConf(const std::string& filename, std::map<std::string, std::string>& confMap);
	bool LoadProc(PipeFile& file, const std::string& name, std::string leftBracket, Procedure& proc);
	bool LoadBlock(PipeFile& file, Block& block, bool parallel);

	bool ReadLeftBracket(PipeFile& file, std::string& leftBracket);

	bool AppendCommandLineFromFile(PipeFile& file, Block& block);
private:
	std::map<std::string, Procedure> procList_;
	std::map<std::string, std::string> procAtLineNo_;
	std::vector<Block> blockList_{1}; // the first 'Block' is the default one.
};

#endif

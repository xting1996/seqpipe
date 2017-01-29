#include <iostream>
#include <fstream>
#include <map>
#include <regex>
#include <cassert>
#include "Pipeline.h"
#include "StringUtils.h"
#include "System.h"

std::string FormatProcCalling(const std::string& procName,
		const std::map<std::string, std::string>& procArgs,
		const std::vector<std::string>& procArgsOrder)
{
	std::string s = procName;
	for (auto name : procArgsOrder) {
		auto it = procArgs.find(name);
		s += " " + name + "=" + System::EncodeShell(it->second);
	}
	return s;
}

CommandItem::CommandItem(const std::string& cmd, const std::vector<std::string>& arguments, const std::string& cmdLine):
	type_(TYPE_SHELL), cmdLine_(cmdLine), shellCmd_(cmd), shellArgs_(arguments)
{
	if (cmdLine_.empty()) {
		cmdLine_ = cmd;
		for (const auto arg : arguments) {
			cmdLine_ += ' ' + System::EncodeShell(arg);
		}
	}
}

CommandItem::CommandItem(const std::string& procName, const std::map<std::string, std::string>& procArgs,
		const std::vector<std::string>& procArgsOrder):
	type_(TYPE_PROC), procName_(procName), procArgs_(procArgs), procArgsOrder_(procArgsOrder)
{
}

std::string CommandItem::ToString() const
{
	if (type_ == TYPE_SHELL) {
		return cmdLine_;
	} else {
		return FormatProcCalling(procName_, procArgs_, procArgsOrder_);
	}
}

void Block::Clear()
{
	items_.clear();
	parallel_ = false;
}

bool Block::AppendCommand(const std::string& cmd, const std::vector<std::string>& arguments)
{
	items_.push_back(CommandItem(cmd, arguments));
	return true;
}

bool Block::AppendCommand(const std::string& line)
{
	std::string cmd;
	std::vector<std::string> arguments;
	if (!StringUtils::ParseCommandLine(line, cmd, arguments)) {
		return false;
	}
	items_.push_back(CommandItem(cmd, arguments));
	return true;
}

bool Block::AppendCommand(const std::string& procName, const std::map<std::string, std::string>& procArgs,
		const std::vector<std::string>& procArgsOrder)
{
	items_.push_back(CommandItem(procName, procArgs, procArgsOrder));
	return true;
}

bool Pipeline::CheckIfPipeFile(const std::string& command)
{
	if (!System::CheckFileExists(command)) {
		return false;
	}
	if (System::HasExecutiveAttribute(command)) {
		return false;
	}
	if (!System::IsTextFile(command)) {
		return false;
	}
	return true;
}

std::vector<std::string> Pipeline::GetProcNameList(const std::string& pattern) const
{
	std::vector<std::string> nameList;
	for (auto it = procList_.begin(); it != procList_.end(); ++it) {
		const auto& name = it->first;
		if (std::regex_search(name, std::regex(pattern))) {
			nameList.push_back(it->first);
		}
	}
	return nameList;
}

bool Pipeline::ReadLeftBracket(PipeFile& file, std::string& leftBracket)
{
	while (file.ReadLine()) {
		if (PipeFile::IsEmptyLine(file.CurrentLine())) {
			continue;
		} else if (PipeFile::IsCommentLine(file.CurrentLine())) {
			if (PipeFile::IsDescLine(file.CurrentLine())) {
				std::cerr << "Error: Unexpected attribute line at " << file.Pos() << std::endl;
				return false;
			}
			continue;
		} else if (!PipeFile::IsLeftBracket(file.CurrentLine(), leftBracket)) {
			std::cerr << "Error: Unexpected line at " << file.Pos() << "\n"
				"   Only '{' or '{{' was expected here." << std::endl;
			return false;
		}
		break;
	}
	return true;
}

bool Pipeline::LoadBlock(PipeFile& file, Block& block, bool parallel)
{
	while (file.ReadLine()) {
		std::string rightBracket;
		if (PipeFile::IsRightBracket(file.CurrentLine(), rightBracket)) {
			if (!parallel && rightBracket == "}}") {
				std::cerr << "Error: Unexpected right bracket at " << file.Pos() << "\n"
					"   Right bracket '}' was expected here." << std::endl;
				return false;
			} else if (parallel && rightBracket == "}") {
				std::cerr << "Error: Unexpected right bracket at " << file.Pos() << "\n"
					"   Right bracket '}}' was expected here." << std::endl;
				return false;
			}
			break;
		} else {
			block.AppendCommand(file.CurrentLine());
		}
	}
	return true;
}

bool Pipeline::LoadProc(PipeFile& file, const std::string& name, std::string leftBracket, Procedure& proc)
{
	if (leftBracket.empty()) {
		if (!ReadLeftBracket(file, leftBracket)) {
			return false;
		}
	}

	Block block;
	if (!LoadBlock(file, block, (leftBracket == "{{"))) {
		return false;
	}
	size_t blockIndex = blockList_.size();
	blockList_.push_back(block);

	procList_[name].Initialize(name, blockIndex);
	return true;
}

bool Pipeline::LoadConf(const std::string& filename, std::map<std::string, std::string>& confMap)
{
	std::ifstream file(filename);
	if (!file.is_open()) {
		return false;
	}

	std::string line;
	size_t lineNo = 0;
	while (std::getline(file, line)) {
		++lineNo;
		std::string name;
		std::string value;
		if (PipeFile::IsVarLine(line, name, value)) {
			confMap[name] = value;
		} else {
			if (!PipeFile::IsEmptyLine(line) && !PipeFile::IsCommentLine(line)) {
				std::cerr << "Error: Invalid syntax of configure file in " << filename << "(" << lineNo << ")\n"
					"  Only global variable definition could be included in configure file!" << std::endl;
				return false;
			}
		}
	}
	file.close();
	return true;
}

bool Pipeline::Load(const std::string& filename)
{
	std::map<std::string, std::string> confMap;
	std::map<std::string, std::string> procAtLineNo;

	PipeFile file;
	if (!file.Open(filename)) {
		return false;
	}
	while (file.ReadLine()) {

		if (PipeFile::IsEmptyLine(file.CurrentLine())) {
			continue;
		}
		if (PipeFile::IsCommentLine(file.CurrentLine())) {
			if (PipeFile::IsDescLine(file.CurrentLine())) {
				if (!PipeFile::ParseAttrLine(file.CurrentLine())) {
					std::cerr << "Warning: Invalid format of attribute at " << file.Pos() << "!" << std::endl;
				}
			}
			continue;
		}

		std::string includeFilename;
		if (PipeFile::IsIncLine(file.CurrentLine(), includeFilename)) {
			std::cerr << "Loading module '" << includeFilename << "'" << std::endl;
			if (!LoadConf(System::DirName(file.Filename()) + "/" + includeFilename, confMap)) {
				return false;
			}
			continue;
		}

		std::string name;
		std::string value;
		if (PipeFile::IsVarLine(file.CurrentLine(), name, value)) {
			confMap[name] = value;
		}

		std::string leftBracket;
		if (PipeFile::IsFuncLine(file.CurrentLine(), name, leftBracket)) {
			if (procAtLineNo.find(name) != procAtLineNo.end()) {
				std::cerr << "Error: Duplicated procedure '" << name << "' at " << file.Pos() << "\n"
					"   Previous definition of '" << name << "' was in " << procAtLineNo[name] << std::endl;
				return false;
			}
			procAtLineNo[name] = file.Pos();

			Procedure proc;
			if (!LoadProc(file, name, leftBracket, proc)) {
				return false;
			}
			continue;
		}

		if (!blockList_[0].AppendCommand(file.CurrentLine())) {
			return false;
		}
	}

	auto confFilename = filename + ".conf";
	if (System::CheckFileExists(confFilename)) {
		if (!LoadConf(confFilename, confMap)) {
			return false;
		}
	}
	return true;
}

bool Pipeline::Save(const std::string& filename) const
{
	std::ofstream file(filename);
	if (!file) {
		return false;
	}

	bool first = true;
	for (auto it = procList_.begin(); it != procList_.end(); ++it) {
		if (first) {
			first = false;
		} else {
			file << "\n";
		}

		file << it->first << "() {\n";
		for (const auto& cmd : blockList_[it->second.BlockIndex()].items_) {
			file << "\t" << cmd.cmdLine_ << "\n";
		}
		file << "}\n";
	}

	if (!blockList_[0].items_.empty()) {
		if (!procList_.empty()) {
			file << "\n";
		}
		for (const auto& item : blockList_[0].items_) {
			file << item.ToString() << "\n";
		}
	}

	file.close();
	return true;
}

bool Pipeline::SetDefaultBlock(const std::vector<std::string>& cmdList, bool parallel)
{
	blockList_[0].Clear();
	for (const auto& cmd : cmdList) {
		if (!blockList_[0].AppendCommand(cmd)) {
			return false;
		}
	}
	blockList_[0].SetParallel(parallel);
	return true;
}

bool Pipeline::SetDefaultBlock(const std::string& cmd, const std::vector<std::string>& arguments)
{
	blockList_[0].Clear();
	return blockList_[0].AppendCommand(cmd, arguments);
}

bool Pipeline::SetDefaultBlock(const std::string& procName, const std::map<std::string, std::string>& procArgs,
		const std::vector<std::string>& procArgsOrder)
{
	blockList_[0].Clear();
	return blockList_[0].AppendCommand(procName, procArgs, procArgsOrder);
}

bool Pipeline::HasProcedure(const std::string& name) const
{
	return procList_.find(name) != procList_.end();
}

const Block& Pipeline::GetDefaultBlock() const
{
	return blockList_[0];
}

const Block& Pipeline::GetBlock(const std::string& procName) const
{
	auto it = procList_.find(procName);
	if (it == procList_.end()) {
		throw std::runtime_error("Invalid procName");
	}
	return blockList_[it->second.BlockIndex()];
}

bool Pipeline::HasAnyDefaultCommand() const
{
	return blockList_[0].HasAnyCommand();
}

void Pipeline::FinalCheckAfterLoad()
{
	for (auto& block : blockList_) {
		for (auto& item : block.items_) {
			if (item.type_ == CommandItem::TYPE_SHELL) {
				if (HasProcedure(item.shellCmd_)) {
					bool failed = false;
					std::map<std::string, std::string> procArgs;
					std::vector<std::string> procArgsOrder;
					for (const auto& arg : item.shellArgs_) {
						std::smatch sm;
						if (!std::regex_match(arg, sm, std::regex("(\\w+)=(.*)"))) {
							failed = true;
							break;
						}
						const auto& key = sm[1];
						const auto& value = sm[2];
						procArgs[key] = value;
						procArgsOrder.push_back(key);
					}
					if (!failed) {
						item.type_ = CommandItem::TYPE_PROC;
						item.procName_ = item.shellCmd_;
						item.procArgs_ = procArgs;
						item.procArgsOrder_ = procArgsOrder;
					}
				}
			}
		}
	}
}

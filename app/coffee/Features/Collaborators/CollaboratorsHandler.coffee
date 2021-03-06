UserCreator = require('../User/UserCreator')
Project = require("../../models/Project").Project
logger = require('logger-sharelatex')
UserGetter = require "../User/UserGetter"
ContactManager = require "../Contacts/ContactManager"
CollaboratorsEmailHandler = require "./CollaboratorsEmailHandler"
async = require "async"
PrivilegeLevels = require "../Authorization/PrivilegeLevels"
Errors = require "../Errors/Errors"
EmailHelper = require "../Helpers/EmailHelper"
ProjectEditorHandler = require "../Project/ProjectEditorHandler"


module.exports = CollaboratorsHandler =

	getMemberIdsWithPrivilegeLevels: (project_id, callback = (error, members) ->) ->
		Project.findOne { _id: project_id }, { owner_ref: 1, collaberator_refs: 1, readOnly_refs: 1 }, (error, project) ->
			return callback(error) if error?
			return callback new Errors.NotFoundError("no project found with id #{project_id}") if !project?
			members = []
			members.push { id: project.owner_ref.toString(), privilegeLevel: PrivilegeLevels.OWNER }
			for member_id in project.readOnly_refs or []
				members.push { id: member_id.toString(), privilegeLevel: PrivilegeLevels.READ_ONLY }
			for member_id in project.collaberator_refs or []
				members.push { id: member_id.toString(), privilegeLevel: PrivilegeLevels.READ_AND_WRITE }
			return callback null, members

	getMemberIds: (project_id, callback = (error, member_ids) ->) ->
		CollaboratorsHandler.getMemberIdsWithPrivilegeLevels project_id, (error, members) ->
			return callback(error) if error?
			return callback null, members.map (m) -> m.id

	USER_PROJECTION: {
		_id: 1,
		email: 1,
		features: 1,
		first_name: 1,
		last_name: 1,
		signUpDate: 1
	}
	getMembersWithPrivilegeLevels: (project_id, callback = (error, members) ->) ->
		CollaboratorsHandler.getMemberIdsWithPrivilegeLevels project_id, (error, members = []) ->
			return callback(error) if error?
			result = []
			async.mapLimit members, 3,
				(member, cb) ->
					UserGetter.getUserOrUserStubById member.id, CollaboratorsHandler.USER_PROJECTION, (error, user) ->
						return cb(error) if error?
						if user?
							result.push { user: user, privilegeLevel: member.privilegeLevel }
						cb()
				(error) ->
					return callback(error) if error?
					callback null, result

	getMemberIdPrivilegeLevel: (user_id, project_id, callback = (error, privilegeLevel) ->) ->
		# In future if the schema changes and getting all member ids is more expensive (multiple documents)
		# then optimise this.
		CollaboratorsHandler.getMemberIdsWithPrivilegeLevels project_id, (error, members = []) ->
			return callback(error) if error?
			for member in members
				if member.id == user_id?.toString()
					return callback null, member.privilegeLevel
			return callback null, PrivilegeLevels.NONE

	getMemberCount: (project_id, callback = (error, count) ->) ->
		CollaboratorsHandler.getMemberIdsWithPrivilegeLevels project_id, (error, members) ->
			return callback(error) if error?
			return callback null, (members or []).length

	getCollaboratorCount: (project_id, callback = (error, count) ->) ->
		CollaboratorsHandler.getMemberCount project_id, (error, count) ->
			return callback(error) if error?
			return callback null, count - 1 # Don't count project owner

	isUserMemberOfProject: (user_id, project_id, callback = (error, isMember, privilegeLevel) ->) ->
		CollaboratorsHandler.getMemberIdsWithPrivilegeLevels project_id, (error, members = []) ->
			return callback(error) if error?
			for member in members
				if member.id.toString() == user_id.toString()
					return callback null, true, member.privilegeLevel
			return callback null, false, null

	getProjectsUserIsCollaboratorOf: (user_id, fields, callback = (error, readAndWriteProjects, readOnlyProjects) ->) ->
		Project.find {collaberator_refs:user_id}, fields, (err, readAndWriteProjects)=>
			return callback(err) if err?
			Project.find {readOnly_refs:user_id}, fields, (err, readOnlyProjects)=>
				return callback(err) if err?
				callback(null, readAndWriteProjects, readOnlyProjects)

	removeUserFromProject: (project_id, user_id, callback = (error) ->)->
		logger.log user_id: user_id, project_id: project_id, "removing user"
		conditions = _id:project_id
		update = $pull:{}
		update["$pull"] = collaberator_refs:user_id, readOnly_refs:user_id
		Project.update conditions, update, (err)->
			if err?
				logger.error err: err, "problem removing user from project collaberators"
			callback(err)

	removeUserFromAllProjets: (user_id, callback = (error) ->) ->
		CollaboratorsHandler.getProjectsUserIsCollaboratorOf user_id, { _id: 1 }, (error, readAndWriteProjects = [], readOnlyProjects = []) ->
			return callback(error) if error?
			allProjects = readAndWriteProjects.concat(readOnlyProjects)
			jobs = []
			for project in allProjects
				do (project) ->
					jobs.push (cb) ->
						return cb() if !project?
						CollaboratorsHandler.removeUserFromProject project._id, user_id, cb
			async.series jobs, callback

	addEmailToProject: (project_id, adding_user_id, unparsed_email, privilegeLevel, callback = (error, user) ->) ->
		email = EmailHelper.parseEmail(unparsed_email)
		if !email? or email == ""
			return callback(new Error("no valid email provided: '#{unparsed_email}'"))
		UserCreator.getUserOrCreateHoldingAccount email, (error, user) ->
			return callback(error) if error?
			CollaboratorsHandler.addUserIdToProject project_id, adding_user_id, user._id, privilegeLevel, (error) ->
				return callback(error) if error?
				return callback null, user._id

	addUserIdToProject: (project_id, adding_user_id, user_id, privilegeLevel, callback = (error) ->)->
		Project.findOne { _id: project_id }, { collaberator_refs: 1, readOnly_refs: 1 }, (error, project) ->
			return callback(error) if error?
			existing_users = (project.collaberator_refs or [])
			existing_users = existing_users.concat(project.readOnly_refs or [])
			existing_users = existing_users.map (u) -> u.toString()
			if existing_users.indexOf(user_id.toString()) > -1
				return callback null # User already in Project

			if privilegeLevel == PrivilegeLevels.READ_AND_WRITE
				level = {"collaberator_refs":user_id}
				logger.log {privileges: "readAndWrite", user_id, project_id}, "adding user"
			else if privilegeLevel == PrivilegeLevels.READ_ONLY
				level = {"readOnly_refs":user_id}
				logger.log {privileges: "readOnly", user_id, project_id}, "adding user"
			else
				return callback(new Error("unknown privilegeLevel: #{privilegeLevel}"))

			ContactManager.addContact adding_user_id, user_id

			Project.update { _id: project_id }, { $addToSet: level }, (error) ->
				return callback(error) if error?
				# Flush to TPDS in background to add files to collaborator's Dropbox
				ProjectEntityHandler = require("../Project/ProjectEntityHandler")
				ProjectEntityHandler.flushProjectToThirdPartyDataStore project_id, (error) ->
					if error?
						logger.error {err: error, project_id, user_id}, "error flushing to TPDS after adding collaborator"
				callback()

	getAllMembers: (projectId, callback=(err, members)->) ->
		logger.log {projectId}, "fetching all members"
		CollaboratorsHandler.getMembersWithPrivilegeLevels projectId, (error, rawMembers) ->
			if error?
				logger.err {projectId, error}, "error getting members for project"
				return callback(error)
			{owner, members} = ProjectEditorHandler.buildOwnerAndMembersViews(rawMembers)
			callback(null, members)

	transferProjects: (from_user_id, to_user_id, callback=(err, projects) ->) ->
		MEMBER_KEYS = ['collaberator_refs', 'readOnly_refs']

		# Find all the projects this user is part of so we can flush them to TPDS
		query =
			$or:
				[{ owner_ref: from_user_id }]
				.concat(
					MEMBER_KEYS.map (key) ->
						q = {}
						q[key] = from_user_id
						return q
				) # [{ collaberator_refs: from_user_id }, ...]
		Project.find query, { _id: 1 }, (error, projects = []) ->
			return callback(error) if error?

			project_ids = projects.map (p) -> p._id
			logger.log {project_ids, from_user_id, to_user_id}, "transferring projects"

			update_jobs = []
			update_jobs.push (cb) ->
				Project.update { owner_ref: from_user_id }, { $set: { owner_ref: to_user_id }}, { multi: true }, cb
			for key in MEMBER_KEYS
				do (key) ->
					update_jobs.push (cb) ->
						query = {}
						addNewUserUpdate = $addToSet: {}
						removeOldUserUpdate = $pull: {}
						query[key] = from_user_id
						removeOldUserUpdate.$pull[key] = from_user_id
						addNewUserUpdate.$addToSet[key] = to_user_id
						# Mongo won't let us pull and addToSet in the same query, so do it in
						# two. Note we need to add first, since the query is based on the old user.
						Project.update query, addNewUserUpdate, { multi: true }, (error) ->
							return cb(error) if error?
							Project.update query, removeOldUserUpdate, { multi: true }, cb

			# Flush each project to TPDS to add files to new user's Dropbox
			ProjectEntityHandler = require("../Project/ProjectEntityHandler")
			flush_jobs = []
			for project_id in project_ids
				do (project_id) ->
					flush_jobs.push (cb) ->
						ProjectEntityHandler.flushProjectToThirdPartyDataStore project_id, cb

			# Flush in background, no need to block on this
			async.series flush_jobs, (error) ->
				if error?
					logger.err {err: error, project_ids, from_user_id, to_user_id}, "error flushing tranferred projects to TPDS"

			async.series update_jobs, callback
